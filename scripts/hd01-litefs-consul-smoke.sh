#!/bin/sh
set -eu

IMAGE=${IMAGE:-cs-storage:hd01-smoke}
SMOKE=${SMOKE:-/tmp/cs-storage-litefs-consul-smoke}
SERVER=${SERVER:-cs-storage-litefs-consul-smoke-server}
NODE_A=${NODE_A:-cs-storage-litefs-consul-smoke-a}
NODE_B=${NODE_B:-cs-storage-litefs-consul-smoke-b}
PORT=${PORT:-18181}
TOKEN=${TOKEN:-cs-litefs-consul-smoke-token}
KEY=${KEY:-cs-storage/litefs/consul-smoke}
PROBE_IMAGE=${PROBE_IMAGE:-busybox:1.36}

case "$SMOKE" in
  /tmp/cs-storage-litefs-consul-smoke*) ;;
  *) echo "REFUSE_SMOKE path=$SMOKE"; exit 1 ;;
esac
case "$SERVER $NODE_A $NODE_B" in
  *cs-storage-litefs-consul-smoke*) ;;
  *) echo "REFUSE_CONTAINER_NAMES"; exit 1 ;;
esac

rm -rf "$SMOKE"
mkdir -p "$SMOKE/a" "$SMOKE/b"
cleanup() {
  docker rm -f "$NODE_B" "$NODE_A" "$SERVER" >/dev/null 2>&1 || true
  rm -rf "$SMOKE"
}
trap cleanup EXIT
cleanup
mkdir -p "$SMOKE/a" "$SMOKE/b"

cat > "$SMOKE/a.yml" <<EOF_A
fuse:
  dir: /mnt/litefs
data:
  dir: /data
http:
  addr: :20202
lease:
  type: consul
  advertise-url: http://127.0.0.1:20202
  candidate: true
  promote: true
  hostname: node-a
  consul:
    url: http://127.0.0.1:$PORT
    key: $KEY
    ttl: 10s
    lock-delay: 1s
EOF_A
cat > "$SMOKE/b.yml" <<EOF_B
fuse:
  dir: /mnt/litefs
data:
  dir: /data
http:
  addr: :20203
lease:
  type: consul
  advertise-url: http://127.0.0.1:20203
  candidate: false
  hostname: node-b
  consul:
    url: http://127.0.0.1:$PORT
    key: $KEY
    ttl: 10s
    lock-delay: 1s
EOF_B

docker run -d --name "$SERVER" --network host \
  -e CS_SERVER_ADDR=127.0.0.1:$PORT \
  -e CS_NODE_SECRET_KEY=litefs-consul-smoke-secret \
  -e CS_BACKEND_URL=http://127.0.0.1:9 \
  -e CS_COORDINATOR_TOKEN=$TOKEN \
  --entrypoint /usr/local/bin/cs-storage-server \
  "$IMAGE" >/tmp/cs-litefs-consul-server.cid
for _ in $(seq 1 80); do
  if docker run --rm --network host "$PROBE_IMAGE" wget -qO- "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done
if ! docker run --rm --network host "$PROBE_IMAGE" wget -qO- "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then
  docker logs "$SERVER" 2>&1 || true
  echo LITEFS_CONSUL_SERVER_NOT_READY
  exit 1
fi

docker run -d --name "$NODE_A" --network host --privileged --cap-add SYS_ADMIN --device /dev/fuse \
  -e CONSUL_HTTP_TOKEN=$TOKEN \
  -v "$SMOKE/a.yml:/etc/litefs.yml:ro" \
  -v "$SMOKE/a:/data" \
  --entrypoint litefs "$IMAGE" mount -config /etc/litefs.yml >/tmp/cs-litefs-consul-a.cid
docker run -d --name "$NODE_B" --network host --privileged --cap-add SYS_ADMIN --device /dev/fuse \
  -e CONSUL_HTTP_TOKEN=$TOKEN \
  -v "$SMOKE/b.yml:/etc/litefs.yml:ro" \
  -v "$SMOKE/b:/data" \
  --entrypoint litefs "$IMAGE" mount -config /etc/litefs.yml >/tmp/cs-litefs-consul-b.cid

for name in "$NODE_A" "$NODE_B"; do
  for _ in $(seq 1 120); do
    if docker exec "$name" test -d /mnt/litefs; then
      break
    fi
    sleep 0.5
  done
  if ! docker exec "$name" test -d /mnt/litefs; then
    docker logs "$name" 2>&1 || true
    echo "LITEFS_CONSUL_NODE_NOT_READY name=$name"
    exit 1
  fi
done

for _ in $(seq 1 120); do
  if docker exec "$NODE_A" sqlite3 /mnt/litefs/main.db "PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS events(node TEXT, n INTEGER, value TEXT); INSERT INTO events VALUES('node-a', 1, 'alpha');" >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done
if ! docker exec "$NODE_A" sqlite3 /mnt/litefs/main.db "SELECT COUNT(*) FROM events;" >/dev/null 2>&1; then
  echo NODE_A_LOGS
  docker logs "$NODE_A" 2>&1 || true
  echo NODE_B_LOGS
  docker logs "$NODE_B" 2>&1 || true
  echo SERVER_LOGS
  docker logs "$SERVER" 2>&1 || true
  echo LITEFS_CONSUL_PRIMARY_WRITE_FAILED
  exit 1
fi

for _ in $(seq 1 120); do
  rows=$(docker exec "$NODE_B" sqlite3 /mnt/litefs/main.db "SELECT COUNT(*) FROM events;" 2>/dev/null || true)
  if test "$rows" = "1"; then
    break
  fi
  sleep 0.5
done
rows=$(docker exec "$NODE_B" sqlite3 /mnt/litefs/main.db "SELECT COUNT(*) FROM events;" 2>/dev/null || true)
integrity=$(docker exec "$NODE_B" sqlite3 /mnt/litefs/main.db "PRAGMA integrity_check;" 2>/dev/null || true)
if test "$rows" != "1" || test "$integrity" != "ok"; then
  echo NODE_A_LOGS
  docker logs "$NODE_A" 2>&1 || true
  echo NODE_B_LOGS
  docker logs "$NODE_B" 2>&1 || true
  echo SERVER_LOGS
  docker logs "$SERVER" 2>&1 || true
  echo "LITEFS_CONSUL_REPLICA_NOT_READY rows=$rows integrity=$integrity"
  exit 1
fi

trap - EXIT
cleanup

echo "LITEFS_CONSUL_SMOKE_OK image=$IMAGE rows=$rows integrity=$integrity coordinator=cs-storage-server nodes=2"
