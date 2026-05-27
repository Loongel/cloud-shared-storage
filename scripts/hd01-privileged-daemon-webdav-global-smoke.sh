#!/bin/sh
set -eu

if test "${CSS_ALLOW_HISTORICAL_SWARM_HOST_HELPER:-}" != "yes"; then
  echo "CSS_HISTORICAL_SWARM_HOST_HELPER_DISABLED script=$0" >&2
  exit 2
fi

GO_BIN=${GO_BIN:-/tmp/cs-storage-go/go/bin/go}
GOFMT_BIN=${GOFMT_BIN:-$(dirname "$GO_BIN")/gofmt}
WORKDIR=${WORKDIR:-/tmp/cs-storage-work-current}
STACK=${STACK:-cs-storage-priv-daemon-webdav-global-smoke}
IMAGE=${IMAGE:-cs-storage:hd01-smoke}
LAUNCHER_IMAGE=${LAUNCHER_IMAGE:-docker:27-cli}
APP_IMAGE=${APP_IMAGE:-alpine:3.20}
SMOKE=${SMOKE:-/tmp/cs-storage-priv-daemon-webdav-global-smoke}
NODES_MIN=${NODES_MIN:-}
DRIVER=${DRIVER:-cs-storage-priv-webdav-smoke}
VOLUME=${VOLUME:-cs-priv-webdav-smoke-vol}
DAEMON_CONTAINER=${DAEMON_CONTAINER:-cs-storage-priv-webdav-smoke-daemon}
PLUGIN_CONTAINER=${PLUGIN_CONTAINER:-cs-storage-priv-webdav-smoke-plugin}
DAEMON_SOCKET=${DAEMON_SOCKET:-/run/cs-storage-priv-webdav-smoke.sock}
PLUGIN_SOCKET=${PLUGIN_SOCKET:-/run/docker/plugins/cs-storage-priv-webdav-smoke.sock}
ROOT_DIR=${ROOT_DIR:-/mnt/cs_storage/vols/.cs-priv-webdav-smoke}
AUDIT_LOG=${AUDIT_LOG:-/var/log/cs-storage/priv-webdav-smoke-audit.jsonl}
SERVER_PORT=${SERVER_PORT:-18132}
SECRET=${SECRET:-cs-priv-webdav-smoke-secret}
REMOTE_ROOT=${REMOTE_ROOT:-cs-storage-priv-webdav-smoke-$(date +%s)-$$}
FILE_NAME=${FILE_NAME:-cs-storage-priv-webdav-workload.txt}
VERIFY_TIMEOUT=${VERIFY_TIMEOUT:-180}
LOG_FETCH_TIMEOUT=${LOG_FETCH_TIMEOUT:-15}

: "${CS_WEBDAV_URL:?CS_WEBDAV_URL is required}"
: "${CS_WEBDAV_USER:?CS_WEBDAV_USER is required}"
: "${CS_WEBDAV_PASSWORD:?CS_WEBDAV_PASSWORD is required}"

case "$DRIVER" in
  cs-storage-priv-webdav-smoke*) ;;
  *) echo "REFUSE_DRIVER name=$DRIVER"; exit 1 ;;
esac
case "$DAEMON_SOCKET" in
  /run/cs-storage-priv-webdav-smoke*.sock) ;;
  *) echo "REFUSE_DAEMON_SOCKET path=$DAEMON_SOCKET"; exit 1 ;;
esac
case "$PLUGIN_SOCKET" in
  /run/docker/plugins/cs-storage-priv-webdav-smoke*.sock) ;;
  *) echo "REFUSE_PLUGIN_SOCKET path=$PLUGIN_SOCKET"; exit 1 ;;
esac
case "$ROOT_DIR" in
  /mnt/cs_storage/vols/.cs-priv-webdav-smoke|/mnt/cs_storage/vols/.cs-priv-webdav-smoke/*) ;;
  *) echo "REFUSE_ROOT_DIR path=$ROOT_DIR"; exit 1 ;;
esac
case "$AUDIT_LOG" in
  /var/log/cs-storage/priv-webdav-smoke*) ;;
  *) echo "REFUSE_AUDIT_LOG path=$AUDIT_LOG"; exit 1 ;;
esac

rm -rf "$SMOKE"
mkdir -p "$SMOKE/bin"

cleanup_stack() {
  docker stack rm "$STACK" >/dev/null 2>&1 || true
  for _ in $(seq 1 90); do
    if ! docker stack ps "$STACK" >/dev/null 2>&1; then
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
server_pid=
cleanup() {
  cleanup_stack
  kill "${server_pid:-}" 2>/dev/null || true
  wait "${server_pid:-}" 2>/dev/null || true
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
  echo "PRIV_WEBDAV_NOT_ENOUGH_NODES ready=$active_nodes min=$NODES_MIN"
  exit 1
fi

cleanup_remote
mkcol() {
  rel=$1
  code=$(curl -sS -o /dev/null -w '%{http_code}' --netrc-file "$NETRC" -X MKCOL "$BASE_URL/$rel" || true)
  case "$code" in
    200|201|204|405) return 0 ;;
    *) echo "WEBDAV_MKCOL_FAILED rel=$rel http=$code"; return 1 ;;
  esac
}
mkcol "$REMOTE_ROOT"
mkcol "$REMOTE_ROOT/nodes"
for node in $(docker node ls --format '{{.Hostname}} {{.Status}}' | awk '$2 == "Ready" {print $1}' | sort -u); do
  mkcol "$REMOTE_ROOT/nodes/$node"
done

cd "$WORKDIR"
"$GOFMT_BIN" -w cmd internal
"$GO_BIN" build -buildvcs=false -o "$SMOKE/bin/cs-storage-server" ./cmd/cs-storage-server
CS_SERVER_ADDR=":$SERVER_PORT" \
CS_NODE_SECRET_KEY="$SECRET" \
CS_BACKEND_URL="$BASE_URL" \
CS_BACKEND_USER="$CS_WEBDAV_USER" \
CS_BACKEND_PASSWORD="$CS_WEBDAV_PASSWORD" \
CS_SANDBOX_PREFIX="/$REMOTE_ROOT/nodes" \
"$SMOKE/bin/cs-storage-server" > "$SMOKE/server.log" 2>&1 &
server_pid=$!
for _ in $(seq 1 100); do
  if curl -fsS "http://127.0.0.1:$SERVER_PORT/healthz" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
curl -fsS "http://127.0.0.1:$SERVER_PORT/healthz" >/dev/null
server_host=${SERVER_HOST:-$(docker node inspect self --format '{{.Status.Addr}}' 2>/dev/null || hostname -I | awk '{print $1}')}
SERVER_URL="http://$server_host:$SERVER_PORT"

cat > "$SMOKE/stack.yml" <<STACK_EOF
version: "3.8"
services:
  launcher:
    image: $LAUNCHER_IMAGE
    environment:
      NODE_ID: "{{.Node.Hostname}}"
    command:
      - sh
      - -c
      - |
        set -eu
        node_id=\$\$(docker info --format '{{.Name}}')
        cleanup() {
          docker volume rm $VOLUME >/dev/null 2>&1 || true
          docker rm -f $PLUGIN_CONTAINER $DAEMON_CONTAINER >/dev/null 2>&1 || true
          rm -f /hostrun/${DAEMON_SOCKET#/run/} /hostrun/docker/plugins/${PLUGIN_SOCKET#/run/docker/plugins/}
        }
        trap cleanup EXIT TERM INT
        cleanup
        mkdir -p /hostrun/docker/plugins /hostmnt/.cs-priv-webdav-smoke /hostlog
        docker run -d --name $DAEMON_CONTAINER \
          --network host \
          --privileged --cap-add SYS_ADMIN --device /dev/fuse \
          -e CS_DAEMON_SOCKET=$DAEMON_SOCKET \
          -e CS_ROOT_DIR=$ROOT_DIR \
          -e CS_STATE_PATH=$ROOT_DIR/.state/volumes.json \
          -e CS_AUDIT_LOG=$AUDIT_LOG \
          -e CS_ENABLE_CHATTR=false \
          -e CS_RECOVER_MOUNTS=false \
          -e CS_SERVER_URL=$SERVER_URL \
          -e CS_RCLONE_ENDPOINT=$SERVER_URL \
          -e CS_NODE_ID=\$\$node_id \
          -e CS_NODE_SECRET_KEY=$SECRET \
          -e CS_RCLONE_VFS_CACHE_MODE=writes \
          -e CS_RCLONE_VFS_WRITE_BACK=0s \
          -e CS_RCLONE_EXTRA_ARGS=--allow-other \
          -v /run:/run \
          -v /mnt/cs_storage/vols:/mnt/cs_storage/vols:rshared \
          -v /var/log/cs-storage:/var/log/cs-storage \
          --entrypoint /usr/bin/cs-storage-daemon \
          $IMAGE >/tmp/daemon.cid
        docker run -d --name $PLUGIN_CONTAINER \
          -e CS_PLUGIN_SOCKET=$PLUGIN_SOCKET \
          -e CS_DAEMON_SOCKET=$DAEMON_SOCKET \
          -e CS_PLUGIN_TIMEOUT=120s \
          -e CS_PLUGIN_SCOPE=local \
          -v /run/docker/plugins:/run/docker/plugins \
          -v /run:/run \
          --entrypoint /usr/bin/cs-storage-plugin \
          $IMAGE >/tmp/plugin.cid
        i=0
        while test "\$\$i" -lt 200; do
          if test -S /hostrun/${DAEMON_SOCKET#/run/} && test -S /hostrun/docker/plugins/${PLUGIN_SOCKET#/run/docker/plugins/}; then
            break
          fi
          i=\$\$((i + 1))
          sleep 0.25
        done
        if ! test -S /hostrun/${DAEMON_SOCKET#/run/} || ! test -S /hostrun/docker/plugins/${PLUGIN_SOCKET#/run/docker/plugins/}; then
          echo PRIV_DAEMON_WEBDAV_SOCKET_WAIT_FAILED node=\$\$node_id
          docker ps -a --filter name=cs-storage-priv-webdav-smoke --format '{{.Names}} {{.Status}} {{.Image}}' || true
          echo DAEMON_CONTAINER_LOGS
          docker logs cs-storage-priv-webdav-smoke-daemon 2>&1 || true
          echo PLUGIN_CONTAINER_LOGS
          docker logs cs-storage-priv-webdav-smoke-plugin 2>&1 || true
          exit 1
        fi
        docker volume create -d $DRIVER -o cs.crypt=false -o cs.mode=private $VOLUME
        docker run --rm -v $VOLUME:/data $APP_IMAGE sh -c 'printf "node=%s\n" "'"\$\$node_id"'" > /data/$FILE_NAME && sync'
        docker volume rm $VOLUME
        test -s /hostlog/${AUDIT_LOG#/var/log/cs-storage/}
        cleanup
        trap - EXIT TERM INT
        echo PRIV_DAEMON_WEBDAV_NODE_OK node=\$\$node_id driver=$DRIVER volume=$VOLUME file=$FILE_NAME
    volumes:
      - type: bind
        source: /var/run/docker.sock
        target: /var/run/docker.sock
      - type: bind
        source: /run
        target: /hostrun
      - type: bind
        source: /mnt/cs_storage/vols
        target: /hostmnt
      - type: bind
        source: /var/log/cs-storage
        target: /hostlog
    deploy:
      mode: global
      restart_policy:
        condition: none
STACK_EOF

docker stack deploy -c "$SMOKE/stack.yml" "$STACK" >/dev/null
service="${STACK}_launcher"
for _ in $(seq 1 300); do
  ok=$(timeout "$LOG_FETCH_TIMEOUT" docker service logs --raw --tail 500 "$service" 2>/dev/null | awk '$1 == "PRIV_DAEMON_WEBDAV_NODE_OK" {n++} END {print n+0}')
  if test "$ok" -ge "$NODES_MIN"; then
    break
  fi
  sleep 1
done

timeout "$LOG_FETCH_TIMEOUT" docker service logs --raw --tail 1000 "$service" > "$SMOKE/logs.txt" 2>&1 || true
cat "$SMOKE/logs.txt"
ok=$(awk '$1 == "PRIV_DAEMON_WEBDAV_NODE_OK" {n++} END {print n+0}' "$SMOKE/logs.txt")
if test "$ok" -lt "$NODES_MIN"; then
  docker service ps "$service" --no-trunc || true
  echo "PRIV_DAEMON_WEBDAV_NOT_READY ok=$ok min=$NODES_MIN ready=$active_nodes image=$IMAGE"
  exit 1
fi

verified=0
for node in $(awk '$1 == "PRIV_DAEMON_WEBDAV_NODE_OK" {for (i=1; i<=NF; i++) if ($i ~ /^node=/) {sub(/^node=/, "", $i); print $i}}' "$SMOKE/logs.txt" | sort -u); do
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
  echo "PRIV_DAEMON_WEBDAV_REMOTE_VERIFY_FAILED verified=$verified min=$NODES_MIN remote_root=$REMOTE_ROOT"
  exit 1
fi

trap - EXIT
cleanup

echo "PRIV_DAEMON_WEBDAV_GLOBAL_SMOKE_OK nodes=$ok verified=$verified ready=$active_nodes image=$IMAGE driver=$DRIVER remote_root=$REMOTE_ROOT"
