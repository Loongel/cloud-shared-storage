#!/bin/sh
set -eu

STACK=${STACK:-cs-storage-gluster-daemon-global-smoke}
IMAGE=${IMAGE:-cs-storage:hd01-smoke}
LAUNCHER_IMAGE=${LAUNCHER_IMAGE:-docker:27-cli}
SMOKE=${SMOKE:-/tmp/cs-storage-gluster-daemon-global-smoke}
NODES_MIN=${NODES_MIN:-}
DRIVER=${DRIVER:-cs-storage-gluster-smoke}
VOLUME=${VOLUME:-cs-gluster-smoke-vol}
GLUSTER_CONTAINER=${GLUSTER_CONTAINER:-cs-storage-gluster-smoke-server}
DAEMON_CONTAINER=${DAEMON_CONTAINER:-cs-storage-gluster-smoke-daemon}
PLUGIN_CONTAINER=${PLUGIN_CONTAINER:-cs-storage-gluster-smoke-plugin}
DAEMON_SOCKET=${DAEMON_SOCKET:-/run/cs-storage-gluster-smoke.sock}
PLUGIN_SOCKET=${PLUGIN_SOCKET:-/run/docker/plugins/cs-storage-gluster-smoke.sock}
ROOT_DIR=${ROOT_DIR:-/mnt/cs_storage/vols/.cs-gluster-smoke}
AUDIT_LOG=${AUDIT_LOG:-/var/log/cs-storage/gluster-smoke-audit.jsonl}
GLUSTER_ROOT=${GLUSTER_ROOT:-/mnt/cs_storage/vols/.cs-gluster-server-smoke}
GLUSTER_VOLUME=${GLUSTER_VOLUME:-gv0}
LOG_FETCH_TIMEOUT=${LOG_FETCH_TIMEOUT:-15}
CONFIG=${CONFIG:-${STACK}-runner-$(date +%s)-$$}

case "$DRIVER" in
  cs-storage-gluster-smoke*) ;;
  *) echo "REFUSE_DRIVER name=$DRIVER"; exit 1 ;;
esac
case "$DAEMON_SOCKET" in
  /run/cs-storage-gluster-smoke*.sock) ;;
  *) echo "REFUSE_DAEMON_SOCKET path=$DAEMON_SOCKET"; exit 1 ;;
esac
case "$PLUGIN_SOCKET" in
  /run/docker/plugins/cs-storage-gluster-smoke*.sock) ;;
  *) echo "REFUSE_PLUGIN_SOCKET path=$PLUGIN_SOCKET"; exit 1 ;;
esac
case "$ROOT_DIR" in
  /mnt/cs_storage/vols/.cs-gluster-smoke|/mnt/cs_storage/vols/.cs-gluster-smoke/*) ;;
  *) echo "REFUSE_ROOT_DIR path=$ROOT_DIR"; exit 1 ;;
esac
case "$GLUSTER_ROOT" in
  /mnt/cs_storage/vols/.cs-gluster-server-smoke|/mnt/cs_storage/vols/.cs-gluster-server-smoke/*) ;;
  *) echo "REFUSE_GLUSTER_ROOT path=$GLUSTER_ROOT"; exit 1 ;;
esac
case "$AUDIT_LOG" in
  /var/log/cs-storage/gluster-smoke*) ;;
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
  docker config rm "$CONFIG" >/dev/null 2>&1 || true
  docker ps -a --filter name=cs-storage-gluster-smoke --format '{{.Names}}' | xargs -r docker rm -f >/dev/null 2>&1 || true
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
  echo "GLUSTER_DAEMON_NOT_ENOUGH_NODES ready=$active_nodes min=$NODES_MIN"
  exit 1
fi

cat > "$SMOKE/runner.sh" <<RUNNER_EOF
#!/bin/sh
set -eu
node_id=\$(docker info --format '{{.Name}}')
cleanup() {
  docker volume rm $VOLUME >/dev/null 2>&1 || true
  docker rm -f $PLUGIN_CONTAINER $DAEMON_CONTAINER $GLUSTER_CONTAINER >/dev/null 2>&1 || true
  rm -f /hostrun/${DAEMON_SOCKET#/run/} /hostrun/docker/plugins/${PLUGIN_SOCKET#/run/docker/plugins/}
}
trap cleanup EXIT TERM INT
cleanup
mkdir -p /hostrun/docker/plugins /hostmnt/.cs-gluster-smoke /hostmnt/.cs-gluster-server-smoke /hostlog
rm -rf /hostmnt/.cs-gluster-server-smoke/*
docker run -d --name $GLUSTER_CONTAINER \
  --network host --privileged \
  -v $GLUSTER_ROOT:/gluster-state \
  --entrypoint sh \
  $IMAGE -c 'set -eu; mkdir -p /gluster-state/etc /gluster-state/lib /gluster-state/log /gluster-state/run /gluster-state/brick; glusterd -N -p /gluster-state/run/glusterd.pid -l /gluster-state/log/glusterd.log --xlator-option management.working-directory=/gluster-state/lib --xlator-option management.transport.socket.listen-port=24007 & brick_host=\$(hostname -I); brick_host=\${brick_host%% *}; test -n "\$brick_host"; for i in \$(seq 1 80); do gluster pool list >/dev/null 2>&1 && break; sleep 0.25; done; gluster volume info $GLUSTER_VOLUME >/dev/null 2>&1 || gluster volume create $GLUSTER_VOLUME \$brick_host:/gluster-state/brick force; gluster volume start $GLUSTER_VOLUME >/dev/null 2>&1 || true; gluster volume info $GLUSTER_VOLUME; sleep infinity'
for i in \$(seq 1 120); do
  if docker exec $GLUSTER_CONTAINER gluster volume status $GLUSTER_VOLUME >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done
if ! docker exec $GLUSTER_CONTAINER gluster volume status $GLUSTER_VOLUME >/dev/null; then
  echo GLUSTER_CONTAINER_LOGS
  docker logs $GLUSTER_CONTAINER 2>&1 || true
  exit 1
fi
docker run -d --name $DAEMON_CONTAINER \
  --network host \
  --privileged --cap-add SYS_ADMIN --device /dev/fuse \
  -e CS_DAEMON_SOCKET=$DAEMON_SOCKET \
  -e CS_ROOT_DIR=$ROOT_DIR \
  -e CS_STATE_PATH=$ROOT_DIR/.state/volumes.json \
  -e CS_AUDIT_LOG=$AUDIT_LOG \
  -e CS_ENABLE_CHATTR=false \
  -e CS_RECOVER_MOUNTS=false \
  -e CS_GLUSTER_REMOTE=127.0.0.1:/$GLUSTER_VOLUME \
  -v /run:/run \
  -v /mnt/cs_storage/vols:/mnt/cs_storage/vols:rshared \
  -v /var/log/cs-storage:/var/log/cs-storage \
  --entrypoint /usr/local/bin/cs-storage-daemon \
  $IMAGE >/tmp/daemon.cid
docker run -d --name $PLUGIN_CONTAINER \
  -e CS_PLUGIN_SOCKET=$PLUGIN_SOCKET \
  -e CS_DAEMON_SOCKET=$DAEMON_SOCKET \
  -e CS_PLUGIN_TIMEOUT=120s \
  -e CS_PLUGIN_SCOPE=local \
  -v /run/docker/plugins:/run/docker/plugins \
  -v /run:/run \
  --entrypoint /usr/local/bin/cs-storage-plugin \
  $IMAGE >/tmp/plugin.cid
i=0
while test "\$i" -lt 200; do
  if test -S /hostrun/${DAEMON_SOCKET#/run/} && test -S /hostrun/docker/plugins/${PLUGIN_SOCKET#/run/docker/plugins/}; then
    break
  fi
  i=\$((i + 1))
  sleep 0.25
done
if ! test -S /hostrun/${DAEMON_SOCKET#/run/} || ! test -S /hostrun/docker/plugins/${PLUGIN_SOCKET#/run/docker/plugins/}; then
  echo GLUSTER_DAEMON_SOCKET_WAIT_FAILED node=\$node_id
  docker ps -a --filter name=cs-storage-gluster-smoke --format '{{.Names}} {{.Status}} {{.Image}}' || true
  echo GLUSTER_CONTAINER_LOGS
  docker logs $GLUSTER_CONTAINER 2>&1 || true
  echo DAEMON_CONTAINER_LOGS
  docker logs $DAEMON_CONTAINER 2>&1 || true
  echo PLUGIN_CONTAINER_LOGS
  docker logs $PLUGIN_CONTAINER 2>&1 || true
  exit 1
fi
docker volume create -d $DRIVER -o flush=true -o cs.crypt=false -o cs.mode=shared -o cs.write=multi -o cs.engine=static $VOLUME
docker run --rm --entrypoint sh -v $VOLUME:/data $IMAGE -c 'set -eu; printf "node=%s\n" "'"\$node_id"'" > /data/static.txt; sync; grep -q "node='"\$node_id"'" /data/static.txt'
test -f /hostmnt/.cs-gluster-smoke/$VOLUME/logs/gluster.log
docker volume rm $VOLUME
cleanup
trap - EXIT TERM INT
echo GLUSTER_DAEMON_NODE_OK node=\$node_id driver=$DRIVER volume=$VOLUME file=static.txt
RUNNER_EOF

docker config rm "$CONFIG" >/dev/null 2>&1 || true
docker config create "$CONFIG" "$SMOKE/runner.sh" >/dev/null

cat > "$SMOKE/stack.yml" <<STACK_EOF
version: "3.8"
services:
  launcher:
    image: $LAUNCHER_IMAGE
    command:
      - sh
      - /cs-storage-gluster-runner.sh
    configs:
      - source: runner
        target: /cs-storage-gluster-runner.sh
        mode: 0555
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
configs:
  runner:
    external: true
    name: $CONFIG
STACK_EOF

docker stack deploy -c "$SMOKE/stack.yml" "$STACK" >/dev/null
service="${STACK}_launcher"
for _ in $(seq 1 180); do
  ok=$(timeout 5 docker service logs --raw --tail 1000 "$service" 2>/dev/null | awk '$1 == "GLUSTER_DAEMON_NODE_OK" {n++} END {print n+0}')
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

timeout "$LOG_FETCH_TIMEOUT" docker service logs --raw --tail 1500 "$service" > "$SMOKE/logs.txt" 2>&1 || true
cat "$SMOKE/logs.txt"
ok=$(awk '$1 == "GLUSTER_DAEMON_NODE_OK" {n++} END {print n+0}' "$SMOKE/logs.txt")
if test "$ok" -lt "$NODES_MIN"; then
  docker service ps "$service" --no-trunc || true
  echo "GLUSTER_DAEMON_GLOBAL_NOT_READY ok=$ok min=$NODES_MIN ready=$active_nodes image=$IMAGE"
  exit 1
fi

trap - EXIT
cleanup

echo "GLUSTER_DAEMON_GLOBAL_SMOKE_OK nodes=$ok ready=$active_nodes image=$IMAGE driver=$DRIVER file=static.txt"
