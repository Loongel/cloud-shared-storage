#!/bin/sh
set -eu

STACK=${STACK:-cs-storage-production-webdav-workload-smoke}
PRECHECK_STACK=${PRECHECK_STACK:-cs-storage-production-webdav-precheck}
IMAGE=${IMAGE:-cs-storage:hd01-smoke}
PROBE_IMAGE=${PROBE_IMAGE:-alpine:3.20}
TESTER_IMAGE=${TESTER_IMAGE:-docker:27-cli}
APP_IMAGE=${APP_IMAGE:-alpine:3.20}
SMOKE=${SMOKE:-/tmp/cs-storage-production-webdav-workload-smoke}
NODES_MIN=${NODES_MIN:-}
DRIVER=${DRIVER:-css}
VOLUME=${VOLUME:-cs-production-webdav-smoke-vol}
DAEMON_SOCKET=${DAEMON_SOCKET:-/run/cs-storage.sock}
PLUGIN_SOCKET=${PLUGIN_SOCKET:-/run/docker/plugins/css.sock}
ROOT_DIR=${ROOT_DIR:-/mnt/cs_storage/vols/.cs-production-webdav-smoke}
AUDIT_LOG=${AUDIT_LOG:-/var/log/cs-storage/production-webdav-smoke-audit.jsonl}
SERVER_PORT=${SERVER_PORT:-18082}
SECRET=${SECRET:-cs-production-webdav-smoke-secret}
REMOTE_ROOT=${REMOTE_ROOT:-cs-storage-production-webdav-smoke-$(date +%s)-$$}
FILE_NAME=${FILE_NAME:-cs-storage-webdav-workload.txt}
VERIFY_TIMEOUT=${VERIFY_TIMEOUT:-180}

: "${CS_WEBDAV_URL:?CS_WEBDAV_URL is required}"
: "${CS_WEBDAV_USER:?CS_WEBDAV_USER is required}"
: "${CS_WEBDAV_PASSWORD:?CS_WEBDAV_PASSWORD is required}"

rm -rf "$SMOKE"
mkdir -p "$SMOKE"

cleanup_stack() {
  stack=$1
  docker stack rm "$stack" >/dev/null 2>&1 || true
  for _ in $(seq 1 90); do
    if ! docker stack ps "$stack" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
}

BASE_URL=${CS_WEBDAV_URL%/}
BASE_HOST=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.urlparse(sys.argv[1]).hostname or "")' "$BASE_URL")
if test -z "$BASE_HOST"; then
  echo INVALID_WEBDAV_URL
  exit 1
fi
NETRC="$SMOKE/curl.netrc"
umask 077
cat > "$NETRC" <<NETRC_EOF
machine $BASE_HOST
login $CS_WEBDAV_USER
password $CS_WEBDAV_PASSWORD
NETRC_EOF
umask 022

cleanup_remote() {
  curl -sS -o /dev/null --netrc-file "$NETRC" -X DELETE "$BASE_URL/$REMOTE_ROOT" >/dev/null 2>&1 || true
}

cleanup() {
  cleanup_stack "$STACK"
  cleanup_stack "$PRECHECK_STACK"
  cleanup_remote
  rm -f "$NETRC"
}
trap cleanup EXIT

state=$(docker info --format '{{.Swarm.LocalNodeState}}')
if test "$state" != "active"; then
  echo "SWARM_NOT_ACTIVE state=$state"
  exit 1
fi

active_nodes=$(docker node ls --format '{{.Status}}' | awk '$1 == "Ready" {n++} END {print n+0}')
if test -z "$NODES_MIN"; then
  NODES_MIN=$active_nodes
fi
if test "$active_nodes" -lt "$NODES_MIN"; then
  echo "PRODUCTION_WEBDAV_WORKLOAD_NOT_ENOUGH_NODES ready=$active_nodes min=$NODES_MIN"
  exit 1
fi

if test "$DRIVER" != "css"; then
  echo "REFUSE_DRIVER name=$DRIVER"
  exit 1
fi
if test "$DAEMON_SOCKET" != "/run/cs-storage.sock" || test "$PLUGIN_SOCKET" != "/run/docker/plugins/css.sock"; then
  echo "REFUSE_SOCKET daemon=$DAEMON_SOCKET plugin=$PLUGIN_SOCKET"
  exit 1
fi
case "$ROOT_DIR" in
  /mnt/cs_storage/vols/.cs-production-webdav-smoke|/mnt/cs_storage/vols/.cs-production-webdav-smoke/*) ;;
  *) echo "REFUSE_ROOT_DIR path=$ROOT_DIR"; exit 1 ;;
esac
case "$AUDIT_LOG" in
  /var/log/cs-storage/production-webdav-smoke*) ;;
  *) echo "REFUSE_AUDIT_LOG path=$AUDIT_LOG"; exit 1 ;;
esac

mkcol() {
  rel=$1
  code=$(curl -sS -o /dev/null -w '%{http_code}' --netrc-file "$NETRC" -X MKCOL "$BASE_URL/$rel" || true)
  case "$code" in
    200|201|204|405) return 0 ;;
    *) echo "WEBDAV_MKCOL_FAILED rel=$rel http=$code"; return 1 ;;
  esac
}

cleanup_remote
mkcol "$REMOTE_ROOT"
mkcol "$REMOTE_ROOT/nodes"
for node in $(docker node ls --format '{{.Hostname}} {{.Status}}' | awk '$2 == "Ready" {print $1}' | sort -u); do
  mkcol "$REMOTE_ROOT/nodes/$node"
done

cat > "$SMOKE/precheck.yml" <<PRECHECK_EOF
version: "3.8"
services:
  precheck:
    image: $PROBE_IMAGE
    command:
      - /bin/sh
      - -c
      - |
        set -eu
        node=\$\$(cat /host/etc/hostname 2>/dev/null || hostname)
        issue=0
        if test -S /host$DAEMON_SOCKET; then
          echo "PRODUCTION_WEBDAV_PRECHECK_ISSUE \$\$node existing_socket=$DAEMON_SOCKET"
          issue=1
        fi
        if test -S /host$PLUGIN_SOCKET; then
          echo "PRODUCTION_WEBDAV_PRECHECK_ISSUE \$\$node existing_socket=$PLUGIN_SOCKET"
          issue=1
        fi
        if test "\$\$issue" -eq 0; then
          echo "PRODUCTION_WEBDAV_PRECHECK_NODE_OK \$\$node"
        fi
        sleep 300
    volumes:
      - type: bind
        source: /
        target: /host
        read_only: true
    deploy:
      mode: global
      restart_policy:
        condition: none
PRECHECK_EOF

docker stack deploy -c "$SMOKE/precheck.yml" "$PRECHECK_STACK" >/dev/null
precheck_service="${PRECHECK_STACK}_precheck"
for _ in $(seq 1 120); do
  ok=$(docker service logs --raw "$precheck_service" 2>/dev/null | awk '$1 == "PRODUCTION_WEBDAV_PRECHECK_NODE_OK" {n++} END {print n+0}')
  issues=$(docker service logs --raw "$precheck_service" 2>/dev/null | awk '$1 == "PRODUCTION_WEBDAV_PRECHECK_ISSUE" {n++} END {print n+0}')
  if test "$issues" -gt 0 || test "$ok" -ge "$NODES_MIN"; then
    break
  fi
  sleep 1
done

docker service logs --raw "$precheck_service" > "$SMOKE/precheck.log" 2>&1 || true
cat "$SMOKE/precheck.log"
issues=$(awk '$1 == "PRODUCTION_WEBDAV_PRECHECK_ISSUE" {n++} END {print n+0}' "$SMOKE/precheck.log")
ok=$(awk '$1 == "PRODUCTION_WEBDAV_PRECHECK_NODE_OK" {n++} END {print n+0}' "$SMOKE/precheck.log")
if test "$issues" -gt 0 || test "$ok" -lt "$NODES_MIN"; then
  docker service ps "$precheck_service" --no-trunc || true
  echo "PRODUCTION_WEBDAV_PRECHECK_FAILED ok=$ok issues=$issues min=$NODES_MIN ready=$active_nodes"
  exit 1
fi
cleanup_stack "$PRECHECK_STACK"

manager_ip=$(hostname -I | awk '{print $1}')
SERVER_URL="http://$manager_ip:$SERVER_PORT"

cat > "$SMOKE/stack.yml" <<STACK_EOF
version: "3.8"
services:
  gateway:
    image: $IMAGE
    entrypoint: ["/usr/bin/cs-storage-server"]
    environment:
      CS_SERVER_ADDR: ":8080"
      CS_NODE_SECRET_KEY: "$SECRET"
      CS_BACKEND_URL: "$BASE_URL"
      CS_BACKEND_USER: "$CS_WEBDAV_USER"
      CS_BACKEND_PASSWORD: "$CS_WEBDAV_PASSWORD"
      CS_SANDBOX_PREFIX: "/$REMOTE_ROOT/nodes"
    ports:
      - target: 8080
        published: $SERVER_PORT
        protocol: tcp
        mode: ingress
    deploy:
      replicas: 1
      restart_policy:
        condition: none
  daemon:
    image: $IMAGE
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        set -eu
        rm -f $DAEMON_SOCKET
        cleanup() { rm -f $DAEMON_SOCKET; }
        trap cleanup EXIT TERM INT
        mkdir -p $ROOT_DIR /var/log/cs-storage
        CS_DAEMON_SOCKET=$DAEMON_SOCKET \\
        CS_ROOT_DIR=$ROOT_DIR \\
        CS_STATE_PATH=$ROOT_DIR/.state/volumes.json \\
        CS_AUDIT_LOG=$AUDIT_LOG \\
        CS_ENABLE_CHATTR=false \\
        CS_RECOVER_MOUNTS=false \\
        CS_SERVER_URL=$SERVER_URL \\
        CS_RCLONE_ENDPOINT=$SERVER_URL \\
        CS_NODE_ID={{.Node.Hostname}} \\
        CS_NODE_SECRET_KEY=$SECRET \\
        CS_RCLONE_VFS_CACHE_MODE=writes \\
        CS_RCLONE_EXTRA_ARGS="--allow-other" \\
        /usr/bin/cs-storage-daemon &
        pid=\$\$!
        wait \$\$pid
    cap_add:
      - SYS_ADMIN
    security_opt:
      - apparmor:unconfined
    volumes:
      - type: bind
        source: /run
        target: /run
      - type: bind
        source: /mnt/cs_storage/vols
        target: /mnt/cs_storage/vols
        bind:
          propagation: rshared
      - type: bind
        source: /var/log/cs-storage
        target: /var/log/cs-storage
    devices:
      - /dev/fuse:/dev/fuse
    deploy:
      mode: global
      restart_policy:
        condition: none
  plugin:
    image: $IMAGE
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        set -eu
        rm -f $PLUGIN_SOCKET
        cleanup() { rm -f $PLUGIN_SOCKET; }
        trap cleanup EXIT TERM INT
        CS_PLUGIN_SOCKET=$PLUGIN_SOCKET \\
        CS_DAEMON_SOCKET=$DAEMON_SOCKET \\
        CS_PLUGIN_TIMEOUT=5s \\
        CS_PLUGIN_SCOPE=local \\
        CS_DOCKER_SOCKET= \\
        /usr/bin/cs-storage-plugin &
        pid=\$\$!
        wait \$\$pid
    volumes:
      - type: bind
        source: /run/docker/plugins
        target: /run/docker/plugins
      - type: bind
        source: /run
        target: /run
    deploy:
      mode: global
      restart_policy:
        condition: none
  tester:
    image: $TESTER_IMAGE
    environment:
      NODE_ID: "{{.Node.Hostname}}"
    command:
      - sh
      - -c
      - |
        set -eu
        i=0
        while test "\$\$i" -lt 200; do
          if test -S $PLUGIN_SOCKET && test -S $DAEMON_SOCKET; then
            break
          fi
          i=\$\$((i + 1))
          sleep 0.25
        done
        test -S $PLUGIN_SOCKET
        test -S $DAEMON_SOCKET
        docker volume rm $VOLUME >/dev/null 2>&1 || true
        docker volume create -d $DRIVER -o cs.crypt=false -o cs.mode=private $VOLUME
        docker run --rm -v $VOLUME:/data $APP_IMAGE sh -c 'printf "node=%s\n" "'"\$\$NODE_ID"'" > /data/$FILE_NAME && sync'
        docker volume rm $VOLUME
        test -s $AUDIT_LOG
        echo PRODUCTION_WEBDAV_WORKLOAD_NODE_OK node=\$\$NODE_ID driver=$DRIVER volume=$VOLUME file=$FILE_NAME
        sleep 300
    volumes:
      - type: bind
        source: /var/run/docker.sock
        target: /var/run/docker.sock
      - type: bind
        source: /run/docker/plugins
        target: /run/docker/plugins
      - type: bind
        source: /run
        target: /run
      - type: bind
        source: /var/log/cs-storage
        target: /var/log/cs-storage
    deploy:
      mode: global
      restart_policy:
        condition: none
STACK_EOF

docker stack deploy -c "$SMOKE/stack.yml" "$STACK" >/dev/null
for _ in $(seq 1 90); do
  if curl -fsS "$SERVER_URL/healthz" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
curl -fsS "$SERVER_URL/healthz" >/dev/null

tester="${STACK}_tester"
for _ in $(seq 1 240); do
  ok=$(docker service logs --raw "$tester" 2>/dev/null | awk '$1 == "PRODUCTION_WEBDAV_WORKLOAD_NODE_OK" {n++} END {print n+0}')
  if test "$ok" -ge "$NODES_MIN"; then
    break
  fi
  sleep 1
done

logs="$SMOKE/logs.txt"
docker service logs --raw "$tester" > "$logs" 2>&1 || true
cat "$logs"
ok=$(awk '$1 == "PRODUCTION_WEBDAV_WORKLOAD_NODE_OK" {n++} END {print n+0}' "$logs")
if test "$ok" -lt "$NODES_MIN"; then
  docker service ps "${STACK}_gateway" --no-trunc || true
  docker service ps "${STACK}_daemon" --no-trunc || true
  docker service ps "${STACK}_plugin" --no-trunc || true
  docker service ps "$tester" --no-trunc || true
  echo GATEWAY_LOGS
  docker service logs --raw "${STACK}_gateway" --tail 120 2>&1 || true
  echo DAEMON_LOGS
  docker service logs --raw "${STACK}_daemon" --tail 120 2>&1 || true
  echo PLUGIN_LOGS
  docker service logs --raw "${STACK}_plugin" --tail 120 2>&1 || true
  echo "PRODUCTION_WEBDAV_WORKLOAD_NOT_READY ok=$ok min=$NODES_MIN ready=$active_nodes image=$IMAGE tester=$TESTER_IMAGE driver=$DRIVER"
  exit 1
fi

verified=0
for node in $(awk '$1 == "PRODUCTION_WEBDAV_WORKLOAD_NODE_OK" {for (i=1; i<=NF; i++) if ($i ~ /^node=/) {sub(/^node=/, "", $i); print $i}}' "$logs" | sort -u); do
  rel="$REMOTE_ROOT/nodes/$node/$FILE_NAME"
  for _ in $(seq 1 "$VERIFY_TIMEOUT"); do
    code=$(curl -sS -o "$SMOKE/propfind-$node.xml" -w '%{http_code}' --netrc-file "$NETRC" -X PROPFIND -H 'Depth: 0' "$BASE_URL/$rel" || true)
    if test "$code" = "207" || test "$code" = "200"; then
      if grep -q '<[^>]*getcontentlength[^>]*>[1-9][0-9]*<' "$SMOKE/propfind-$node.xml" 2>/dev/null; then
        verified=$((verified + 1))
        break
      fi
    fi
    sleep 1
  done
done

if test "$verified" -lt "$NODES_MIN"; then
  echo "PRODUCTION_WEBDAV_REMOTE_VERIFY_FAILED verified=$verified min=$NODES_MIN remote_root=$REMOTE_ROOT"
  exit 1
fi

trap - EXIT
cleanup

echo "PRODUCTION_WEBDAV_WORKLOAD_SMOKE_OK nodes=$ok verified=$verified ready=$active_nodes image=$IMAGE tester=$TESTER_IMAGE driver=$DRIVER remote_root=$REMOTE_ROOT"
