#!/bin/sh
set -eu

STACK=${STACK:-cs-storage-production-driver-smoke}
PRECHECK_STACK=${PRECHECK_STACK:-cs-storage-production-driver-precheck}
IMAGE=${IMAGE:-cs-storage:hd01-smoke}
PROBE_IMAGE=${PROBE_IMAGE:-alpine:3.20}
TESTER_IMAGE=${TESTER_IMAGE:-docker:27-cli}
SMOKE=${SMOKE:-/tmp/cs-storage-production-driver-smoke}
NODES_MIN=${NODES_MIN:-}
DRIVER=${DRIVER:-css}
VOLUME=${VOLUME:-cs-production-driver-smoke-vol}
DAEMON_SOCKET=${DAEMON_SOCKET:-/run/cs-storage.sock}
PLUGIN_SOCKET=${PLUGIN_SOCKET:-/run/docker/plugins/css.sock}
ROOT_DIR=${ROOT_DIR:-/mnt/cs_storage/vols/.cs-production-driver-smoke}
AUDIT_LOG=${AUDIT_LOG:-/var/log/cs-storage/production-driver-smoke-audit.jsonl}

rm -rf "$SMOKE"
mkdir -p "$SMOKE"

cleanup_stack() {
  stack=$1
  docker stack rm "$stack" >/dev/null 2>&1 || true
  for _ in $(seq 1 60); do
    if ! docker stack ps "$stack" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
}

cleanup() {
  cleanup_stack "$STACK"
  cleanup_stack "$PRECHECK_STACK"
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
  echo "PRODUCTION_DRIVER_NOT_ENOUGH_NODES ready=$active_nodes min=$NODES_MIN"
  exit 1
fi

if test "$DRIVER" != "css"; then
  echo "REFUSE_DRIVER name=$DRIVER"
  exit 1
fi
if test "$DAEMON_SOCKET" != "/run/cs-storage.sock"; then
  echo "REFUSE_DAEMON_SOCKET path=$DAEMON_SOCKET"
  exit 1
fi
if test "$PLUGIN_SOCKET" != "/run/docker/plugins/css.sock"; then
  echo "REFUSE_PLUGIN_SOCKET path=$PLUGIN_SOCKET"
  exit 1
fi
case "$ROOT_DIR" in
  /mnt/cs_storage/vols/.cs-production-driver-smoke|/mnt/cs_storage/vols/.cs-production-driver-smoke/*) ;;
  *) echo "REFUSE_ROOT_DIR path=$ROOT_DIR"; exit 1 ;;
esac
case "$AUDIT_LOG" in
  /var/log/cs-storage/production-driver-smoke*) ;;
  *) echo "REFUSE_AUDIT_LOG path=$AUDIT_LOG"; exit 1 ;;
esac

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
          echo "PRODUCTION_DRIVER_PRECHECK_ISSUE \$\$node existing_socket=$DAEMON_SOCKET"
          issue=1
        fi
        if test -S /host$PLUGIN_SOCKET; then
          echo "PRODUCTION_DRIVER_PRECHECK_ISSUE \$\$node existing_socket=$PLUGIN_SOCKET"
          issue=1
        fi
        if test "\$\$issue" -eq 0; then
          echo "PRODUCTION_DRIVER_PRECHECK_NODE_OK \$\$node"
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
  ok=$(docker service logs --raw "$precheck_service" 2>/dev/null | awk '$1 == "PRODUCTION_DRIVER_PRECHECK_NODE_OK" {n++} END {print n+0}')
  issues=$(docker service logs --raw "$precheck_service" 2>/dev/null | awk '$1 == "PRODUCTION_DRIVER_PRECHECK_ISSUE" {n++} END {print n+0}')
  if test "$issues" -gt 0 || test "$ok" -ge "$NODES_MIN"; then
    break
  fi
  sleep 1
done

docker service logs --raw "$precheck_service" > "$SMOKE/precheck.log" 2>&1 || true
cat "$SMOKE/precheck.log"
issues=$(awk '$1 == "PRODUCTION_DRIVER_PRECHECK_ISSUE" {n++} END {print n+0}' "$SMOKE/precheck.log")
ok=$(awk '$1 == "PRODUCTION_DRIVER_PRECHECK_NODE_OK" {n++} END {print n+0}' "$SMOKE/precheck.log")
if test "$issues" -gt 0 || test "$ok" -lt "$NODES_MIN"; then
  docker service ps "$precheck_service" --no-trunc || true
  echo "PRODUCTION_DRIVER_PRECHECK_FAILED ok=$ok issues=$issues min=$NODES_MIN ready=$active_nodes"
  exit 1
fi
cleanup_stack "$PRECHECK_STACK"

cat > "$SMOKE/stack.yml" <<STACK_EOF
version: "3.8"
services:
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
        /usr/bin/cs-storage-daemon &
        pid=\$\$!
        wait \$\$pid
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
        CS_PLUGIN_TIMEOUT=3s \\
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
    command:
      - sh
      - -c
      - |
        set -eu
        i=0
        while test "\$\$i" -lt 160; do
          if test -S $PLUGIN_SOCKET && test -S $DAEMON_SOCKET; then
            break
          fi
          i=\$\$((i + 1))
          sleep 0.25
        done
        test -S $PLUGIN_SOCKET
        test -S $DAEMON_SOCKET
        docker volume rm $VOLUME >/dev/null 2>&1 || true
        docker volume create -d $DRIVER -o cs.crypt=false $VOLUME
        docker volume inspect $VOLUME >/tmp/volume.json
        docker volume rm $VOLUME
        test -s $AUDIT_LOG
        echo PRODUCTION_DRIVER_NODE_OK driver=$DRIVER volume=$VOLUME root=$ROOT_DIR
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
tester="${STACK}_tester"
for _ in $(seq 1 180); do
  ok=$(docker service logs --raw "$tester" 2>/dev/null | awk '$1 == "PRODUCTION_DRIVER_NODE_OK" {n++} END {print n+0}')
  if test "$ok" -ge "$NODES_MIN"; then
    break
  fi
  sleep 1
done

logs="$SMOKE/logs.txt"
docker service logs --raw "$tester" > "$logs" 2>&1 || true
cat "$logs"
ok=$(awk '$1 == "PRODUCTION_DRIVER_NODE_OK" {n++} END {print n+0}' "$logs")
if test "$ok" -lt "$NODES_MIN"; then
  docker service ps "${STACK}_daemon" --no-trunc || true
  docker service ps "${STACK}_plugin" --no-trunc || true
  docker service ps "$tester" --no-trunc || true
  echo DAEMON_LOGS
  docker service logs --raw "${STACK}_daemon" --tail 120 2>&1 || true
  echo PLUGIN_LOGS
  docker service logs --raw "${STACK}_plugin" --tail 120 2>&1 || true
  echo "PRODUCTION_DRIVER_SMOKE_NOT_READY ok=$ok min=$NODES_MIN ready=$active_nodes image=$IMAGE tester=$TESTER_IMAGE driver=$DRIVER"
  exit 1
fi

trap - EXIT
cleanup

echo "PRODUCTION_DRIVER_SMOKE_OK nodes=$ok ready=$active_nodes image=$IMAGE tester=$TESTER_IMAGE driver=$DRIVER root=$ROOT_DIR"
