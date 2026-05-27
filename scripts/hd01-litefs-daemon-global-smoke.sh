#!/bin/sh
set -eu

if test "${CSS_ALLOW_HISTORICAL_SWARM_HOST_HELPER:-}" != "yes"; then
  echo "CSS_HISTORICAL_SWARM_HOST_HELPER_DISABLED script=$0" >&2
  exit 2
fi

STACK=${STACK:-cs-storage-litefs-daemon-global-smoke}
IMAGE=${IMAGE:-cs-storage:hd01-smoke}
LAUNCHER_IMAGE=${LAUNCHER_IMAGE:-docker:27-cli}
SMOKE=${SMOKE:-/tmp/cs-storage-litefs-daemon-global-smoke}
NODES_MIN=${NODES_MIN:-}
DRIVER=${DRIVER:-cs-storage-litefs-smoke}
VOLUME=${VOLUME:-cs-litefs-smoke-vol}
DAEMON_CONTAINER=${DAEMON_CONTAINER:-cs-storage-litefs-smoke-daemon}
PLUGIN_CONTAINER=${PLUGIN_CONTAINER:-cs-storage-litefs-smoke-plugin}
DAEMON_SOCKET=${DAEMON_SOCKET:-/run/cs-storage-litefs-smoke.sock}
PLUGIN_SOCKET=${PLUGIN_SOCKET:-/run/docker/plugins/cs-storage-litefs-smoke.sock}
ROOT_DIR=${ROOT_DIR:-/mnt/cs_storage/vols/.cs-litefs-smoke}
AUDIT_LOG=${AUDIT_LOG:-/var/log/cs-storage/litefs-smoke-audit.jsonl}
LOG_FETCH_TIMEOUT=${LOG_FETCH_TIMEOUT:-15}

case "$DRIVER" in
  cs-storage-litefs-smoke*) ;;
  *) echo "REFUSE_DRIVER name=$DRIVER"; exit 1 ;;
esac
case "$DAEMON_SOCKET" in
  /run/cs-storage-litefs-smoke*.sock) ;;
  *) echo "REFUSE_DAEMON_SOCKET path=$DAEMON_SOCKET"; exit 1 ;;
esac
case "$PLUGIN_SOCKET" in
  /run/docker/plugins/cs-storage-litefs-smoke*.sock) ;;
  *) echo "REFUSE_PLUGIN_SOCKET path=$PLUGIN_SOCKET"; exit 1 ;;
esac
case "$ROOT_DIR" in
  /mnt/cs_storage/vols/.cs-litefs-smoke|/mnt/cs_storage/vols/.cs-litefs-smoke/*) ;;
  *) echo "REFUSE_ROOT_DIR path=$ROOT_DIR"; exit 1 ;;
esac
case "$AUDIT_LOG" in
  /var/log/cs-storage/litefs-smoke*) ;;
  *) echo "REFUSE_AUDIT_LOG path=$AUDIT_LOG"; exit 1 ;;
esac

rm -rf "$SMOKE"
mkdir -p "$SMOKE"
cleanup_stack() {
  docker stack rm "$STACK" >/dev/null 2>&1 || true
  for _ in $(seq 1 90); do
    if ! docker stack ls --format '{{.Name}}' | grep -qx "$STACK"; then
      break
    fi
    sleep 1
  done
}
cleanup() {
  cleanup_stack
  docker ps -a --filter name=cs-storage-litefs-smoke --format '{{.Names}}' | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker volume rm "$VOLUME" >/dev/null 2>&1 || true
  rm -f "$DAEMON_SOCKET" "$PLUGIN_SOCKET"
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
  echo "LITEFS_DAEMON_NOT_ENOUGH_NODES ready=$active_nodes min=$NODES_MIN"
  exit 1
fi

cat > "$SMOKE/stack.yml" <<STACK_EOF
version: "3.8"
services:
  launcher:
    image: $LAUNCHER_IMAGE
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
        mkdir -p /hostrun/docker/plugins /hostmnt/.cs-litefs-smoke /hostlog
        docker run -d --name $DAEMON_CONTAINER \
          --network host \
          --privileged --cap-add SYS_ADMIN --device /dev/fuse \
          -e CS_DAEMON_SOCKET=$DAEMON_SOCKET \
          -e CS_ROOT_DIR=$ROOT_DIR \
          -e CS_STATE_PATH=$ROOT_DIR/.state/volumes.json \
          -e CS_AUDIT_LOG=$AUDIT_LOG \
          -e CS_ENABLE_CHATTR=false \
          -e CS_RECOVER_MOUNTS=false \
          -e CS_LITEFS_HTTP_ADDR=127.0.0.1:20202 \
          -e CS_LITEFS_LEASE_TYPE=static \
          -e CS_LITEFS_ADVERTISE_URL=http://127.0.0.1:20202 \
          -e CS_LITEFS_CANDIDATE=true \
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
          echo LITEFS_DAEMON_SOCKET_WAIT_FAILED node=\$\$node_id
          docker ps -a --filter name=cs-storage-litefs-smoke --format '{{.Names}} {{.Status}} {{.Image}}' || true
          echo DAEMON_CONTAINER_LOGS
          docker logs $DAEMON_CONTAINER 2>&1 || true
          echo PLUGIN_CONTAINER_LOGS
          docker logs $PLUGIN_CONTAINER 2>&1 || true
          exit 1
        fi
        docker volume create -d $DRIVER -o flush=true -o cs.crypt=false -o cs.mode=shared -o cs.write=multi -o cs.engine=sqlite $VOLUME
        docker run --rm --entrypoint sh -v $VOLUME:/data $IMAGE -c 'set -eu; sqlite3 /data/main.db "PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS events(node TEXT, n INTEGER, value TEXT); WITH RECURSIVE cnt(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM cnt WHERE x<20) INSERT INTO events(node,n,value) SELECT '\''smoke'\'', x, '\''value-'\''||x FROM cnt;" >/tmp/sqlite.out; integrity=\$\$(sqlite3 /data/main.db "PRAGMA integrity_check;"); rows=\$\$(sqlite3 /data/main.db "SELECT COUNT(*) FROM events;"); test "\$\$integrity" = ok; test "\$\$rows" = 20; printf "integrity=%s rows=%s\n" "\$\$integrity" "\$\$rows"' > /tmp/litefs-sqlite.out
        grep -q 'integrity=ok rows=20' /tmp/litefs-sqlite.out
        test -s /hostmnt/.cs-litefs-smoke/$VOLUME/logs/litefs.log
        docker volume rm $VOLUME
        cleanup
        trap - EXIT TERM INT
        echo LITEFS_DAEMON_NODE_OK node=\$\$node_id driver=$DRIVER volume=$VOLUME rows=20 integrity=ok
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
for _ in $(seq 1 120); do
  ok=$(timeout 5 docker service logs --raw --tail 800 "$service" 2>/dev/null | awk '$1 == "LITEFS_DAEMON_NODE_OK" {n++} END {print n+0}')
  if test "$ok" -ge "$NODES_MIN"; then
    break
  fi
  active=$(docker service ps "$service" --format "{{.CurrentState}}" 2>/dev/null | awk '/New|Pending|Assigned|Accepted|Ready|Preparing|Starting|Running/ {n++} END {print n+0}')
  failed=$(docker service ps "$service" --format "{{.CurrentState}}" 2>/dev/null | awk '/Failed|Rejected/ {n++} END {print n+0}')
  if test "$active" -eq 0 && test "$failed" -gt 0; then
    break
  fi
  sleep 1
done

timeout "$LOG_FETCH_TIMEOUT" docker service logs --raw --tail 1200 "$service" > "$SMOKE/logs.txt" 2>&1 || true
cat "$SMOKE/logs.txt"
ok=$(awk '$1 == "LITEFS_DAEMON_NODE_OK" {n++} END {print n+0}' "$SMOKE/logs.txt")
if test "$ok" -lt "$NODES_MIN"; then
  docker service ps "$service" --no-trunc || true
  echo DAEMON_CONTAINER_LOGS
  docker ps -a --filter name=cs-storage-litefs-smoke --format '{{.Names}} {{.Status}} {{.Image}}' || true
  echo "LITEFS_DAEMON_GLOBAL_NOT_READY ok=$ok min=$NODES_MIN ready=$active_nodes image=$IMAGE"
  exit 1
fi

trap - EXIT
cleanup

echo "LITEFS_DAEMON_GLOBAL_SMOKE_OK nodes=$ok ready=$active_nodes image=$IMAGE driver=$DRIVER rows_per_node=20 integrity=ok"
