#!/bin/sh
set -eu

STACK=${STACK:-cs-storage-litefs-consul-remote-write-smoke}
IMAGE=${IMAGE:-cs-storage:hd01-smoke}
LAUNCHER_IMAGE=${LAUNCHER_IMAGE:-docker:27-cli}
PROBE_IMAGE=${PROBE_IMAGE:-busybox:1.36}
SMOKE=${SMOKE:-/tmp/cs-storage-litefs-consul-remote-write-smoke}
NODES_MIN=${NODES_MIN:-}
SERVER=${SERVER:-cs-storage-litefs-consul-remote-write-smoke-server}
NODE_CONTAINER=${NODE_CONTAINER:-cs-storage-litefs-consul-remote-write-smoke-node}
ROOT=${ROOT:-/mnt/cs_storage/vols/.cs-litefs-consul-remote-write-smoke}
PORT=${PORT:-18183}
LITEFS_PORT=${LITEFS_PORT:-20213}
TOKEN=${TOKEN:-cs-litefs-consul-remote-write-smoke-token}
KEY=${KEY:-cs-storage/litefs/consul-remote-write-smoke}
CONFIG=${CONFIG:-cs-litefs-consul-rw-$(date +%s)-$$}
ROWS_PER_NODE=${ROWS_PER_NODE:-8}
LOG_FETCH_TIMEOUT=${LOG_FETCH_TIMEOUT:-25}

case "$ROOT" in
  /mnt/cs_storage/vols/.cs-litefs-consul-remote-write-smoke|/mnt/cs_storage/vols/.cs-litefs-consul-remote-write-smoke/*) ;;
  *) echo "REFUSE_ROOT path=$ROOT"; exit 1 ;;
esac
case "$SERVER $NODE_CONTAINER" in
  *cs-storage-litefs-consul-remote-write-smoke*) ;;
  *) echo "REFUSE_CONTAINER_NAMES"; exit 1 ;;
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
  docker rm -f "$SERVER" >/dev/null 2>&1 || true
  docker ps -a --filter name="$NODE_CONTAINER" --format '{{.Names}}' | xargs -r docker rm -f >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup
mkdir -p "$SMOKE"

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
  echo "LITEFS_CONSUL_RW_NOT_ENOUGH_NODES ready=$active_nodes min=$NODES_MIN"
  exit 1
fi
manager_node=$(docker info --format '{{.Name}}')
manager_ip=$(docker node inspect "$manager_node" --format '{{.Status.Addr}}')
test -n "$manager_ip"
server_url="http://$manager_ip:$PORT"
expected_rows=$((active_nodes * ROWS_PER_NODE + 1))
node_cases=$(docker node ls --format '{{.Hostname}} {{.Status}}' | awk '$2 == "Ready" {print $1}' | sort | while read -r node; do ip=$(docker node inspect "$node" --format '{{.Status.Addr}}'); printf "  %s) node_ip=%s ;;\n" "$node" "$ip"; done)

docker run -d --name "$SERVER" --network host \
  -e CS_SERVER_ADDR=:$PORT \
  -e CS_NODE_SECRET_KEY=litefs-consul-remote-write-smoke-secret \
  -e CS_BACKEND_URL=http://127.0.0.1:9 \
  -e CS_COORDINATOR_TOKEN=$TOKEN \
  --entrypoint /usr/bin/cs-storage-server \
  "$IMAGE" >/tmp/cs-litefs-consul-rw-server.cid
for _ in $(seq 1 80); do
  if docker run --rm --network host "$PROBE_IMAGE" wget -qO- "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done
if ! docker run --rm --network host "$PROBE_IMAGE" wget -qO- "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then
  docker logs "$SERVER" 2>&1 || true
  echo LITEFS_CONSUL_RW_SERVER_NOT_READY
  exit 1
fi

cat > "$SMOKE/runner.sh" <<RUNNER_EOF
#!/bin/sh
set -eu
node_id=\$(docker info --format '{{.Name}}')
case "\$node_id" in
$node_cases
  *) echo LITEFS_CONSUL_RW_UNKNOWN_NODE node=\$node_id; exit 1 ;;
esac
role=replica
candidate=true
promote_line=""
if test "\$node_id" = "$manager_node"; then
  role=primary
  promote_line="  promote: true"
fi
cleanup() {
  docker rm -f $NODE_CONTAINER >/dev/null 2>&1 || true
  rm -rf /hostmnt/.cs-litefs-consul-remote-write-smoke/\$node_id
}
trap cleanup EXIT TERM INT
cleanup
mkdir -p /hostmnt/.cs-litefs-consul-remote-write-smoke/\$node_id/data
cat > /hostmnt/.cs-litefs-consul-remote-write-smoke/\$node_id/litefs.yml <<EOF_LITEFS
fuse:
  dir: /mnt/litefs
data:
  dir: /data
http:
  addr: :$LITEFS_PORT
lease:
  type: consul
  advertise-url: http://\$node_ip:$LITEFS_PORT
  candidate: \$candidate
\$promote_line
  hostname: \$node_id
  consul:
    url: $server_url
    key: $KEY
    ttl: 10s
    lock-delay: 1s
EOF_LITEFS
cat > /hostmnt/.cs-litefs-consul-remote-write-smoke/\$node_id/writer.sh <<'EOF_WRITER'
#!/bin/sh
set -eu
i=1
while test "\$i" -le "\$ROWS_PER_NODE"; do
  sqlite3 /mnt/litefs/main.db "PRAGMA busy_timeout=10000; INSERT OR IGNORE INTO events VALUES('\$NODE_ID', \$i, 'rw-\$i');"
  i=\$((i + 1))
done
EOF_WRITER
chmod 755 /hostmnt/.cs-litefs-consul-remote-write-smoke/\$node_id/writer.sh
docker run -d --name $NODE_CONTAINER --network host --privileged --cap-add SYS_ADMIN --device /dev/fuse \
  -e CONSUL_HTTP_TOKEN=$TOKEN \
  -v /mnt/cs_storage/vols/.cs-litefs-consul-remote-write-smoke/\$node_id/litefs.yml:/etc/litefs.yml:ro \
  -v /mnt/cs_storage/vols/.cs-litefs-consul-remote-write-smoke/\$node_id/data:/data \
  -v /mnt/cs_storage/vols/.cs-litefs-consul-remote-write-smoke/\$node_id:/smoke \
  --entrypoint litefs $IMAGE mount -config /etc/litefs.yml >/tmp/cs-litefs-consul-rw-node.cid
for _ in \$(seq 1 120); do
  if docker exec $NODE_CONTAINER test -d /mnt/litefs; then
    break
  fi
  sleep 0.5
done
if ! docker exec $NODE_CONTAINER test -d /mnt/litefs; then
  docker logs $NODE_CONTAINER 2>&1 || true
  echo LITEFS_CONSUL_RW_NODE_NOT_READY node=\$node_id role=\$role
  exit 1
fi
if test "\$role" = primary; then
  for _ in \$(seq 1 120); do
    if docker exec $NODE_CONTAINER sqlite3 /mnt/litefs/main.db "PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000; CREATE TABLE IF NOT EXISTS events(node TEXT, n INTEGER, value TEXT, PRIMARY KEY(node,n)); INSERT OR IGNORE INTO events VALUES('init', 0, 'ready');" >/dev/null 2>&1; then
      break
    fi
    sleep 0.5
  done
fi
for _ in \$(seq 1 180); do
  init_rows=\$(docker exec $NODE_CONTAINER sqlite3 /mnt/litefs/main.db "SELECT COUNT(*) FROM events WHERE node='init';" 2>/dev/null || true)
  if test "\$init_rows" = 1; then
    break
  fi
  sleep 0.5
done
init_rows=\$(docker exec $NODE_CONTAINER sqlite3 /mnt/litefs/main.db "SELECT COUNT(*) FROM events WHERE node='init';" 2>/dev/null || true)
if test "\$init_rows" != 1; then
  docker logs $NODE_CONTAINER 2>&1 || true
  echo LITEFS_CONSUL_RW_INIT_NOT_VISIBLE node=\$node_id role=\$role init_rows=\$init_rows
  exit 1
fi
if test "\$role" = primary; then
  docker exec -e NODE_ID="\$node_id" -e ROWS_PER_NODE=$ROWS_PER_NODE $NODE_CONTAINER sh /smoke/writer.sh >/tmp/cs-litefs-consul-rw-write.out 2>&1 || {
    cat /tmp/cs-litefs-consul-rw-write.out || true
    docker logs $NODE_CONTAINER 2>&1 || true
    echo LITEFS_CONSUL_RW_WRITE_FAILED node=\$node_id role=\$role
    exit 1
  }
else
  wrote=false
  for attempt in \$(seq 1 20); do
    if docker exec -e NODE_ID="\$node_id" -e ROWS_PER_NODE=$ROWS_PER_NODE $NODE_CONTAINER litefs run -url http://127.0.0.1:$LITEFS_PORT -promote -- sh /smoke/writer.sh >/tmp/cs-litefs-consul-rw-write.out 2>&1; then
      wrote=true
      break
    fi
    sleep 1
  done
  if test "\$wrote" != true; then
    cat /tmp/cs-litefs-consul-rw-write.out || true
    docker logs $NODE_CONTAINER 2>&1 || true
    echo LITEFS_CONSUL_RW_WRITE_FAILED node=\$node_id role=\$role
    exit 1
  fi
fi
for _ in \$(seq 1 240); do
  rows=\$(docker exec $NODE_CONTAINER sqlite3 /mnt/litefs/main.db "SELECT COUNT(*) FROM events;" 2>/dev/null || true)
  if test "\$rows" = "$expected_rows"; then
    break
  fi
  sleep 0.5
done
rows=\$(docker exec $NODE_CONTAINER sqlite3 /mnt/litefs/main.db "SELECT COUNT(*) FROM events;" 2>/dev/null || true)
integrity=\$(docker exec $NODE_CONTAINER sqlite3 /mnt/litefs/main.db "PRAGMA integrity_check;" 2>/dev/null || true)
if test "\$rows" != "$expected_rows" || test "\$integrity" != ok; then
  docker logs $NODE_CONTAINER 2>&1 || true
  echo LITEFS_CONSUL_RW_NOT_REPLICATED node=\$node_id role=\$role rows=\$rows expected=$expected_rows integrity=\$integrity
  exit 1
fi
echo LITEFS_CONSUL_RW_NODE_OK node=\$node_id role=\$role rows=\$rows expected=$expected_rows writes=$ROWS_PER_NODE integrity=\$integrity
sleep 300
RUNNER_EOF

docker config rm "$CONFIG" >/dev/null 2>&1 || true
docker config create "$CONFIG" "$SMOKE/runner.sh" >/dev/null
cat > "$SMOKE/stack.yml" <<STACK_EOF
version: "3.8"
services:
  launcher:
    image: $LAUNCHER_IMAGE
    command: ["sh", "/cs-storage-litefs-consul-rw-runner.sh"]
    configs:
      - source: runner
        target: /cs-storage-litefs-consul-rw-runner.sh
        mode: 0555
    volumes:
      - type: bind
        source: /var/run/docker.sock
        target: /var/run/docker.sock
      - type: bind
        source: /mnt/cs_storage/vols
        target: /hostmnt
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
for _ in $(seq 1 300); do
  docker service logs --raw --tail 2000 "$service" > "$SMOKE/logs.txt" 2>/dev/null || true
  ok=$(awk '$1 == "LITEFS_CONSUL_RW_NODE_OK" {n++} END {print n+0}' "$SMOKE/logs.txt")
  if test "$ok" -ge "$NODES_MIN"; then
    break
  fi
  active=$(docker service ps "$service" --format '{{.CurrentState}}' 2>/dev/null | awk '/New|Pending|Assigned|Accepted|Ready|Preparing|Starting|Running/ {n++} END {print n+0}')
  failed=$(docker service ps "$service" --format '{{.CurrentState}}' 2>/dev/null | awk '/Failed|Rejected/ {n++} END {print n+0}')
  if test "$active" -eq 0 && test "$failed" -gt 0; then
    break
  fi
  sleep 1
done
timeout "$LOG_FETCH_TIMEOUT" docker service logs --raw --tail 2500 "$service" > "$SMOKE/logs.txt" 2>&1 || true
cat "$SMOKE/logs.txt"
ok=$(awk '$1 == "LITEFS_CONSUL_RW_NODE_OK" {n++} END {print n+0}' "$SMOKE/logs.txt")
if test "$ok" -lt "$NODES_MIN"; then
  docker service ps "$service" --no-trunc || true
  echo SERVER_LOGS
  docker logs "$SERVER" 2>&1 || true
  echo "LITEFS_CONSUL_RW_NOT_READY ok=$ok min=$NODES_MIN ready=$active_nodes image=$IMAGE coordinator=$server_url expected_rows=$expected_rows"
  exit 1
fi

trap - EXIT
cleanup

echo "LITEFS_CONSUL_REMOTE_WRITE_SMOKE_OK nodes=$ok ready=$active_nodes image=$IMAGE coordinator=$server_url rows=$expected_rows writes_per_node=$ROWS_PER_NODE integrity=ok"
