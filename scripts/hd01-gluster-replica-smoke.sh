#!/bin/sh
set -eu

if test "${CSS_ALLOW_HISTORICAL_SWARM_HOST_HELPER:-}" != "yes"; then
  echo "CSS_HISTORICAL_SWARM_HOST_HELPER_DISABLED script=$0" >&2
  exit 2
fi

STACK=${STACK:-cs-storage-gluster-replica-smoke}
CLIENT_STACK=${CLIENT_STACK:-${STACK}-client}
IMAGE=${IMAGE:-cs-storage:hd01-smoke}
LAUNCHER_IMAGE=${LAUNCHER_IMAGE:-docker:27-cli}
SMOKE=${SMOKE:-/tmp/cs-storage-gluster-replica-smoke}
NODES_MIN=${NODES_MIN:-}
VOLUME=${VOLUME:-gv_cs_replica_smoke}
SERVER_CONTAINER=${SERVER_CONTAINER:-cs-storage-gluster-replica-smoke-server}
CLIENT_CONTAINER=${CLIENT_CONTAINER:-cs-storage-gluster-replica-smoke-client}
GLUSTER_ROOT=${GLUSTER_ROOT:-/mnt/cs_storage/vols/.cs-gluster-replica-smoke}
LOG_FETCH_TIMEOUT=${LOG_FETCH_TIMEOUT:-20}
SERVER_CONFIG=${SERVER_CONFIG:-cs-gluster-rep-srv-$(date +%s)-$$}
CLIENT_CONFIG=${CLIENT_CONFIG:-cs-gluster-rep-cli-$(date +%s)-$$}

case "$SERVER_CONTAINER" in
  cs-storage-gluster-replica-smoke*) ;;
  *) echo "REFUSE_SERVER_CONTAINER name=$SERVER_CONTAINER"; exit 1 ;;
esac
case "$CLIENT_CONTAINER" in
  cs-storage-gluster-replica-smoke*) ;;
  *) echo "REFUSE_CLIENT_CONTAINER name=$CLIENT_CONTAINER"; exit 1 ;;
esac
case "$GLUSTER_ROOT" in
  /mnt/cs_storage/vols/.cs-gluster-replica-smoke|/mnt/cs_storage/vols/.cs-gluster-replica-smoke/*) ;;
  *) echo "REFUSE_GLUSTER_ROOT path=$GLUSTER_ROOT"; exit 1 ;;
esac
case "$VOLUME" in
  gv_cs_replica_smoke*) ;;
  *) echo "REFUSE_VOLUME name=$VOLUME"; exit 1 ;;
esac

rm -rf "$SMOKE"
mkdir -p "$SMOKE"
cleanup_stack() {
  docker stack rm "$CLIENT_STACK" >/dev/null 2>&1 || true
  docker stack rm "$STACK" >/dev/null 2>&1 || true
  for _ in $(seq 1 90); do
    if ! docker stack ls --format '{{.Name}}' | grep -Eq "^($STACK|$CLIENT_STACK)$"; then
      break
    fi
    sleep 1
  done
}
cleanup() {
  cleanup_stack
  docker config rm "$SERVER_CONFIG" "$CLIENT_CONFIG" >/dev/null 2>&1 || true
  docker ps -a --filter name=cs-storage-gluster-replica-smoke --format '{{.Names}}' | xargs -r docker rm -f >/dev/null 2>&1 || true
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
  echo "GLUSTER_REPLICA_NOT_ENOUGH_NODES ready=$active_nodes min=$NODES_MIN"
  exit 1
fi
if test "$active_nodes" -lt 3; then
  echo "GLUSTER_REPLICA_NEEDS_THREE_NODES ready=$active_nodes"
  exit 1
fi

cat > "$SMOKE/server-runner.sh" <<SERVER_EOF
#!/bin/sh
set -eu
node_id=\$(docker info --format '{{.Name}}')
cleanup() {
  docker rm -f $SERVER_CONTAINER >/dev/null 2>&1 || true
  rm -rf /hostmnt/.cs-gluster-replica-smoke/*
}
trap cleanup EXIT TERM INT
cleanup
mkdir -p /hostmnt/.cs-gluster-replica-smoke /hostlog
rm -rf /hostmnt/.cs-gluster-replica-smoke/*
docker run -d --name $SERVER_CONTAINER \
  --network host --privileged \
  -v $GLUSTER_ROOT:/gluster-state \
  --entrypoint sh \
  $IMAGE -c 'set -eu; mkdir -p /gluster-state/lib /gluster-state/log /gluster-state/run /gluster-state/brick; glusterd -N -p /gluster-state/run/glusterd.pid -l /gluster-state/log/glusterd.log --xlator-option management.working-directory=/gluster-state/lib --xlator-option management.transport.socket.listen-port=24007; sleep infinity'
for i in \$(seq 1 120); do
  if docker exec $SERVER_CONTAINER gluster pool list >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done
if ! docker exec $SERVER_CONTAINER gluster pool list >/dev/null 2>&1; then
  echo GLUSTER_REPLICA_SERVER_WAIT_FAILED node=\$node_id
  docker logs $SERVER_CONTAINER 2>&1 || true
  exit 1
fi
ip=\$(docker run --rm --network host --entrypoint sh $IMAGE -c 'set -eu; for ip in \$(hostname -I); do case "\$ip" in 127.*|172.17.*|172.18.*|172.19.*|169.254.*|fe80:*) continue ;; *) printf "%s" "\$ip"; exit 0 ;; esac; done; hostname -I | cut -d " " -f1')
test -n "\$ip"
echo GLUSTER_REPLICA_SERVER_READY node=\$node_id ip=\$ip
sleep 900
SERVER_EOF

docker config rm "$SERVER_CONFIG" >/dev/null 2>&1 || true
docker config create "$SERVER_CONFIG" "$SMOKE/server-runner.sh" >/dev/null

cat > "$SMOKE/server-stack.yml" <<STACK_EOF
version: "3.8"
services:
  launcher:
    image: $LAUNCHER_IMAGE
    command: ["sh", "/cs-storage-gluster-replica-server.sh"]
    configs:
      - source: runner
        target: /cs-storage-gluster-replica-server.sh
        mode: 0555
    volumes:
      - type: bind
        source: /var/run/docker.sock
        target: /var/run/docker.sock
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
    name: $SERVER_CONFIG
STACK_EOF

docker stack deploy -c "$SMOKE/server-stack.yml" "$STACK" >/dev/null
server_service="${STACK}_launcher"
for _ in $(seq 1 180); do
  docker service logs --raw --tail 1200 "$server_service" > "$SMOKE/server-logs.txt" 2>/dev/null || true
  ready=$(awk '$1 == "GLUSTER_REPLICA_SERVER_READY" {n++} END {print n+0}' "$SMOKE/server-logs.txt")
  if test "$ready" -ge "$NODES_MIN"; then
    break
  fi
  sleep 1
done
cat "$SMOKE/server-logs.txt"
ready=$(awk '$1 == "GLUSTER_REPLICA_SERVER_READY" {n++} END {print n+0}' "$SMOKE/server-logs.txt")
if test "$ready" -lt "$NODES_MIN"; then
  docker service ps "$server_service" --no-trunc || true
  echo "GLUSTER_REPLICA_SERVERS_NOT_READY ready=$ready min=$NODES_MIN swarm_ready=$active_nodes image=$IMAGE"
  exit 1
fi

docker node ls --format '{{.Hostname}} {{.Status}}' | awk '$2 == "Ready" {print $1}' | sort | while read -r node; do
  ip=$(docker node inspect "$node" --format '{{.Status.Addr}}')
  test -n "$ip"
  printf "%s %s\n" "$node" "$ip"
done > "$SMOKE/nodes.tsv"
brick_count=$(awk 'END {print NR+0}' "$SMOKE/nodes.tsv")
if test "$brick_count" -lt 3; then
  echo "GLUSTER_REPLICA_NOT_ENOUGH_UNIQUE_SERVERS unique=$brick_count"
  exit 1
fi
manager_node=$(docker info --format '{{.Name}}')
manager_ip=$(awk -v n="$manager_node" '$1 == n {print $2; exit}' "$SMOKE/nodes.tsv")
if test -z "$manager_ip"; then
  manager_ip=$(awk 'NR == 1 {print $2}' "$SMOKE/nodes.tsv")
fi
awk 'NR <= 3 {print $2}' "$SMOKE/nodes.tsv" > "$SMOKE/bricks.txt"

for ip in $(cat "$SMOKE/bricks.txt"); do
  if test "$ip" != "$manager_ip"; then
    docker exec "$SERVER_CONTAINER" gluster peer probe "$ip" >/dev/null 2>&1 || true
  fi
done
for _ in $(seq 1 90); do
  connected=$(docker exec "$SERVER_CONTAINER" gluster peer status 2>/dev/null | awk '/State: Peer in Cluster \(Connected\)/ {n++} END {print n+0}')
  if test "$connected" -ge 2; then
    break
  fi
  sleep 1
done
connected=$(docker exec "$SERVER_CONTAINER" gluster peer status 2>/dev/null | awk '/State: Peer in Cluster \(Connected\)/ {n++} END {print n+0}')
if test "$connected" -lt 2; then
  docker exec "$SERVER_CONTAINER" gluster peer status || true
  echo "GLUSTER_REPLICA_PEERS_NOT_CONNECTED connected=$connected"
  exit 1
fi
bricks=""
while read -r ip; do
  bricks="$bricks $ip:/gluster-state/brick"
done < "$SMOKE/bricks.txt"
docker exec "$SERVER_CONTAINER" gluster volume info "$VOLUME" >/dev/null 2>&1 || docker exec "$SERVER_CONTAINER" gluster volume create "$VOLUME" replica 3 arbiter 1 $bricks force
docker exec "$SERVER_CONTAINER" gluster volume start "$VOLUME" >/dev/null 2>&1 || true
docker exec "$SERVER_CONTAINER" gluster volume status "$VOLUME" >/dev/null

cat > "$SMOKE/client-runner.sh" <<CLIENT_EOF
#!/bin/sh
set -eu
node_id=\$(docker info --format '{{.Name}}')
cleanup() {
  docker rm -f $CLIENT_CONTAINER >/dev/null 2>&1 || true
}
trap cleanup EXIT TERM INT
cleanup
docker run --name $CLIENT_CONTAINER --rm \
  --network host --privileged --cap-add SYS_ADMIN --device /dev/fuse \
  --entrypoint sh $IMAGE -c 'set -eu; mkdir -p /mnt/gluster; mount.glusterfs $manager_ip:/$VOLUME /mnt/gluster; mkdir -p /mnt/gluster/writes; printf "node=%s\n" "'"\$node_id"'" > /mnt/gluster/writes/'"\$node_id"'.txt; sync; for i in \$(seq 1 120); do count=\$(find /mnt/gluster/writes -type f -name "*.txt" 2>/dev/null | wc -l); test "\$count" -ge $NODES_MIN && break; sleep 1; done; count=\$(find /mnt/gluster/writes -type f -name "*.txt" 2>/dev/null | wc -l); test "\$count" -ge $NODES_MIN; grep -R "^node=" /mnt/gluster/writes >/tmp/gluster-writes.txt; umount /mnt/gluster; printf "files=%s\n" "\$count"'
echo GLUSTER_REPLICA_CLIENT_OK node=\$node_id files=$NODES_MIN remote=$manager_ip:/$VOLUME
CLIENT_EOF

docker config rm "$CLIENT_CONFIG" >/dev/null 2>&1 || true
docker config create "$CLIENT_CONFIG" "$SMOKE/client-runner.sh" >/dev/null
cat > "$SMOKE/client-stack.yml" <<CLIENT_STACK_EOF
version: "3.8"
services:
  client:
    image: $LAUNCHER_IMAGE
    command: ["sh", "/cs-storage-gluster-replica-client.sh"]
    configs:
      - source: runner
        target: /cs-storage-gluster-replica-client.sh
        mode: 0555
    volumes:
      - type: bind
        source: /var/run/docker.sock
        target: /var/run/docker.sock
    deploy:
      mode: global
      restart_policy:
        condition: none
configs:
  runner:
    external: true
    name: $CLIENT_CONFIG
CLIENT_STACK_EOF

docker stack deploy -c "$SMOKE/client-stack.yml" "$CLIENT_STACK" >/dev/null
client_service="${CLIENT_STACK}_client"
for _ in $(seq 1 180); do
  docker service logs --raw --tail 1200 "$client_service" > "$SMOKE/client-logs.txt" 2>/dev/null || true
  ok=$(awk '$1 == "GLUSTER_REPLICA_CLIENT_OK" {n++} END {print n+0}' "$SMOKE/client-logs.txt")
  if test "$ok" -ge "$NODES_MIN"; then
    break
  fi
  active=$(docker service ps "$client_service" --format '{{.CurrentState}}' 2>/dev/null | awk '/New|Pending|Assigned|Accepted|Ready|Preparing|Starting|Running/ {n++} END {print n+0}')
  failed=$(docker service ps "$client_service" --format '{{.CurrentState}}' 2>/dev/null | awk '/Failed|Rejected/ {n++} END {print n+0}')
  if test "$active" -eq 0 && test "$failed" -gt 0; then
    break
  fi
  sleep 1
done
timeout "$LOG_FETCH_TIMEOUT" docker service logs --raw --tail 1500 "$client_service" > "$SMOKE/client-logs.txt" 2>&1 || true
cat "$SMOKE/client-logs.txt"
ok=$(awk '$1 == "GLUSTER_REPLICA_CLIENT_OK" {n++} END {print n+0}' "$SMOKE/client-logs.txt")
if test "$ok" -lt "$NODES_MIN"; then
  docker service ps "$client_service" --no-trunc || true
  echo "GLUSTER_REPLICA_CLIENTS_NOT_READY ok=$ok min=$NODES_MIN ready=$active_nodes image=$IMAGE remote=$manager_ip:/$VOLUME"
  exit 1
fi

trap - EXIT
cleanup

echo "GLUSTER_REPLICA_SMOKE_OK clients=$ok ready=$active_nodes bricks=3 arbiter=1 image=$IMAGE volume=$VOLUME remote=$manager_ip:/$VOLUME"
