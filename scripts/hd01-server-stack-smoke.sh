#!/bin/sh
set -eu
STACK=${STACK:-cs-storage-server-smoke}
IMAGE=${IMAGE:-cs-storage:hd01-smoke}
PORT=${PORT:-18080}
cleanup() {
  docker stack rm "$STACK" >/dev/null 2>&1 || true
  for _ in $(seq 1 60); do
    if ! docker stack ps "$STACK" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
}
trap cleanup EXIT
state=$(docker info --format '{{.Swarm.LocalNodeState}}')
if test "$state" != "active"; then
  echo "SWARM_NOT_ACTIVE state=$state"
  exit 1
fi
CS_STORAGE_IMAGE="$IMAGE" CS_NODE_SECRET_KEY=dummy CS_BACKEND_URL=http://127.0.0.1:9 CS_SERVER_PORT="$PORT" docker stack deploy -c deploy/stack/cs-storage-server.yml "$STACK" >/dev/null
service="${STACK}_gateway"
for _ in $(seq 1 120); do
  running=$(docker service ps "$service" --filter desired-state=running --format '{{.CurrentState}}' 2>/dev/null | awk '$1 == "Running" {n++} END {print n+0}')
  if test "$running" -ge 1; then
    break
  fi
  sleep 1
done
running=$(docker service ps "$service" --filter desired-state=running --format '{{.CurrentState}}' 2>/dev/null | awk '$1 == "Running" {n++} END {print n+0}')
if test "$running" -lt 1; then
  docker service ps "$service" --no-trunc || true
  echo "SERVER_STACK_NOT_RUNNING running=$running image=$IMAGE"
  exit 1
fi
for _ in $(seq 1 60); do
  if curl -fsS "http://127.0.0.1:${PORT}/healthz" >/dev/null; then
    trap - EXIT
    cleanup
    echo "SERVER_STACK_SMOKE_OK image=$IMAGE port=$PORT"
    exit 0
  fi
  sleep 1
done
docker service logs --raw "$service" --tail 80 || true
echo "SERVER_STACK_HEALTHZ_FAILED image=$IMAGE port=$PORT"
exit 1
