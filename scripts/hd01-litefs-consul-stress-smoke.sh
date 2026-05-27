#!/bin/sh
set -eu

if test "${CSS_ALLOW_HISTORICAL_SWARM_HOST_HELPER:-}" != "yes"; then
  echo "CSS_HISTORICAL_SWARM_HOST_HELPER_DISABLED script=$0" >&2
  exit 2
fi

STACK=${STACK:-cs-storage-litefs-consul-stress-smoke}
IMAGE=${IMAGE:-cs-storage:hd01-smoke}
LAUNCHER_IMAGE=${LAUNCHER_IMAGE:-docker:27-cli}
PROBE_IMAGE=${PROBE_IMAGE:-busybox:1.36}
SMOKE=${SMOKE:-/tmp/cs-storage-litefs-consul-stress-smoke}
NODES_MIN=${NODES_MIN:-}
SERVER=${SERVER:-cs-storage-litefs-consul-stress-smoke-server}
NODE_CONTAINER=${NODE_CONTAINER:-cs-storage-litefs-consul-stress-smoke-node}
ROOT=${ROOT:-/mnt/cs_storage/vols/.cs-litefs-consul-stress-smoke}
PORT=${PORT:-18193}
LITEFS_PORT=${LITEFS_PORT:-20223}
TOKEN=${TOKEN:-cs-litefs-consul-stress-smoke-token}
KEY=${KEY:-cs-storage/litefs/consul-stress-smoke}
CONFIG=${CONFIG:-cs-litefs-consul-stress-$(date +%s)-$$}
LOG_FETCH_TIMEOUT=${LOG_FETCH_TIMEOUT:-35}
ROWS_PER_PRIMARY=${ROWS_PER_PRIMARY:-512}

case "$ROOT" in
  /mnt/cs_storage/vols/.cs-litefs-consul-stress-smoke|/mnt/cs_storage/vols/.cs-litefs-consul-stress-smoke/*) ;;
  *) echo "REFUSE_ROOT path=$ROOT"; exit 1 ;;
esac
case "$SERVER $NODE_CONTAINER" in
  *cs-storage-litefs-consul-stress-smoke*) ;;
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
  echo "LITEFS_CONSUL_STRESS_NOT_ENOUGH_NODES ready=$active_nodes min=$NODES_MIN"
  exit 1
fi
manager_node=$(docker info --format '{{.Name}}')
manager_ip=$(docker node inspect "$manager_node" --format '{{.Status.Addr}}')
test -n "$manager_ip"
server_url="http://$manager_ip:$PORT"
expected_rows=$ROWS_PER_PRIMARY
node_cases=$(docker node ls --format '{{.Hostname}} {{.Status}}' | awk '$2 == "Ready" {print $1}' | sort | while read -r node; do ip=$(docker node inspect "$node" --format '{{.Status.Addr}}'); printf "  %s) node_ip=%s ;;\n" "$node" "$ip"; done)

docker run -d --name "$SERVER" --network host \
  -e CS_SERVER_ADDR=:$PORT \
  -e CS_NODE_SECRET_KEY=litefs-consul-stress-smoke-secret \
  -e CS_BACKEND_URL=http://127.0.0.1:9 \
  -e CS_COORDINATOR_TOKEN=$TOKEN \
  --entrypoint /usr/bin/cs-storage-server \
  "$IMAGE" >/tmp/cs-litefs-consul-stress-server.cid
for _ in $(seq 1 80); do
  if docker run --rm --network host "$PROBE_IMAGE" wget -qO- "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done
if ! docker run --rm --network host "$PROBE_IMAGE" wget -qO- "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then
  docker logs "$SERVER" 2>&1 || true
  echo LITEFS_CONSUL_STRESS_SERVER_NOT_READY
  exit 1
fi

cat > "$SMOKE/runner.sh" <<RUNNER_EOF
#!/bin/sh
set -eu
node_id=\$(docker info --format '{{.Name}}')
case "\$node_id" in
$node_cases
  *) echo LITEFS_CONSUL_STRESS_UNKNOWN_NODE node=\$node_id; exit 1 ;;
esac
role=replica
candidate=false
promote_line=""
if test "\$node_id" = "$manager_node"; then
  role=primary
  candidate=true
  promote_line="  promote: true"
fi
cleanup() {
  docker rm -f $NODE_CONTAINER >/dev/null 2>&1 || true
  rm -rf /hostmnt/.cs-litefs-consul-stress-smoke/\$node_id
}
trap cleanup EXIT TERM INT
cleanup
mkdir -p /hostmnt/.cs-litefs-consul-stress-smoke/\$node_id
cat > /hostmnt/.cs-litefs-consul-stress-smoke/\$node_id/litefs.yml <<EOF_LITEFS
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
docker run -d --name $NODE_CONTAINER --network host --privileged --cap-add SYS_ADMIN --device /dev/fuse \
  -e CONSUL_HTTP_TOKEN=$TOKEN \
  -v /mnt/cs_storage/vols/.cs-litefs-consul-stress-smoke/\$node_id/litefs.yml:/etc/litefs.yml:ro \
  -v /mnt/cs_storage/vols/.cs-litefs-consul-stress-smoke/\$node_id:/data \
  --entrypoint litefs $IMAGE mount -config /etc/litefs.yml >/tmp/cs-litefs-consul-stress-node.cid
for _ in \$(seq 1 120); do
  if docker exec $NODE_CONTAINER test -d /mnt/litefs; then
    break
  fi
  sleep 0.5
done
if ! docker exec $NODE_CONTAINER test -d /mnt/litefs; then
  docker logs $NODE_CONTAINER 2>&1 || true
  echo LITEFS_CONSUL_STRESS_NODE_NOT_READY node=\$node_id role=\$role
  exit 1
fi
if test "\$role" = primary; then
  for _ in \$(seq 1 120); do
    if docker exec $NODE_CONTAINER sqlite3 /mnt/litefs/main.db "PRAGMA journal_mode=WAL; PRAGMA busy_timeout=10000; CREATE TABLE IF NOT EXISTS events(node TEXT, n INTEGER, value TEXT, PRIMARY KEY(node,n)); WITH RECURSIVE cnt(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM cnt WHERE x<$ROWS_PER_PRIMARY) INSERT OR IGNORE INTO events(node,n,value) SELECT '\$node_id', x, 'stress-'||x FROM cnt;" >/dev/null 2>&1; then
      break
    fi
    sleep 0.5
  done
fi
for _ in \$(seq 1 240); do
  rows=\$(docker exec $NODE_CONTAINER sqlite3 /mnt/litefs/main.db "SELECT COUNT(*) FROM events;" 2>/dev/null || true)
  if test "\$rows" = "$ROWS_PER_PRIMARY"; then
    break
  fi
  sleep 0.5
done
rows=\$(docker exec $NODE_CONTAINER sqlite3 /mnt/litefs/main.db "SELECT COUNT(*) FROM events;" 2>/dev/null || true)
integrity=\$(docker exec $NODE_CONTAINER sqlite3 /mnt/litefs/main.db "PRAGMA integrity_check;" 2>/dev/null || true)
if test "\$rows" != "$ROWS_PER_PRIMARY" || test "\$integrity" != ok; then
  docker logs $NODE_CONTAINER 2>&1 || true
  echo LITEFS_CONSUL_STRESS_REPLICA_NOT_READY node=\$node_id role=\$role rows=\$rows expected=$ROWS_PER_PRIMARY integrity=\$integrity
  exit 1
fi
echo LITEFS_CONSUL_STRESS_NODE_OK node=\$node_id role=\$role rows=\$rows expected=$ROWS_PER_PRIMARY integrity=\$integrity
sleep 300
RUNNER_EOF

docker config rm "$CONFIG" >/dev/null 2>&1 || true
docker config create "$CONFIG" "$SMOKE/runner.sh" >/dev/null
cat > "$SMOKE/stack.yml" <<STACK_EOF
version: "3.8"
services:
  launcher:
    image: $LAUNCHER_IMAGE
    command: ["sh", "/cs-storage-litefs-consul-stress-runner.sh"]
    configs:
      - source: runner
        target: /cs-storage-litefs-consul-stress-runner.sh
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
complete=0
for _ in $(seq 1 240); do
  timeout 10s docker service logs --raw --tail 1500 "$service" > "$SMOKE/logs.txt" 2>/dev/null || true
  ok=$(awk '$1 == "LITEFS_CONSUL_STRESS_NODE_OK" {n++} END {print n+0}' "$SMOKE/logs.txt")
  complete=$(docker service ps "$service" --format '{{.CurrentState}}' 2>/dev/null | awk '/Complete/ {n++} END {print n+0}')
  if test "$ok" -ge "$NODES_MIN" || test "$complete" -ge "$NODES_MIN"; then
    break
  fi
  active=$(docker service ps "$service" --format '{{.CurrentState}}' 2>/dev/null | awk '/New|Pending|Assigned|Accepted|Ready|Preparing|Starting|Running/ {n++} END {print n+0}')
  failed=$(docker service ps "$service" --format '{{.CurrentState}}' 2>/dev/null | awk '/Failed|Rejected/ {n++} END {print n+0}')
  if test "$active" -eq 0 && test "$failed" -gt 0; then
    break
  fi
  sleep 1
done
timeout "$LOG_FETCH_TIMEOUT" docker service logs --raw --tail 2000 "$service" > "$SMOKE/logs.txt" 2>&1 || true
cat "$SMOKE/logs.txt"
ok=$(awk '$1 == "LITEFS_CONSUL_STRESS_NODE_OK" {n++} END {print n+0}' "$SMOKE/logs.txt")
complete=$(docker service ps "$service" --format '{{.CurrentState}}' 2>/dev/null | awk '/Complete/ {n++} END {print n+0}')
if test "$ok" -lt "$NODES_MIN" && test "$complete" -lt "$NODES_MIN"; then
  docker service ps "$service" --no-trunc || true
  echo SERVER_LOGS
  docker logs "$SERVER" 2>&1 || true
  echo "LITEFS_CONSUL_STRESS_NOT_READY ok=$ok complete=$complete min=$NODES_MIN ready=$active_nodes image=$IMAGE coordinator=$server_url expected_rows=$ROWS_PER_PRIMARY"
  exit 1
fi
if test "$ok" -lt "$NODES_MIN"; then
  echo "LITEFS_CONSUL_STRESS_LOG_PARTIAL ok=$ok complete=$complete min=$NODES_MIN"
fi

trap - EXIT
cleanup

echo "LITEFS_CONSUL_STRESS_SMOKE_OK nodes=$complete log_ok=$ok ready=$active_nodes image=$IMAGE coordinator=$server_url primary=$manager_node rows=$ROWS_PER_PRIMARY integrity=ok"
