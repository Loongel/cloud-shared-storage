#!/bin/sh
set -eu
STACK=${STACK:-cs-storage-stack-smoke}
IMAGE=${IMAGE:-busybox:latest}
SMOKE=${SMOKE:-/tmp/cs-stack-smoke}
NODES_MIN=${NODES_MIN:-}
rm -rf "$SMOKE"
mkdir -p "$SMOKE"
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
active_nodes=$(docker node ls --format '{{.Status}}' | awk '$1 == "Ready" {n++} END {print n+0}')
if test -z "$NODES_MIN"; then
  NODES_MIN=$active_nodes
fi
if test "$active_nodes" -lt "$NODES_MIN"; then
  echo "SWARM_NOT_ENOUGH_NODES ready=$active_nodes min=$NODES_MIN"
  exit 1
fi
cat > "$SMOKE/stack.yml" <<EOF
version: "3.8"
services:
  probe:
    image: $IMAGE
    command: ["sh", "-c", "hostname; sleep 300"]
    networks:
      - csnet
    deploy:
      mode: global
      restart_policy:
        condition: none
networks:
  csnet:
    driver: overlay
EOF
docker stack deploy -c "$SMOKE/stack.yml" "$STACK" >/dev/null
service="${STACK}_probe"
for _ in $(seq 1 120); do
  nodes=$(docker service ps "$service" --filter desired-state=running --format '{{.Node}} {{.CurrentState}}' 2>/dev/null | awk '$2 == "Running" {print $1}' | sort -u | wc -l)
  if test "$nodes" -ge "$NODES_MIN"; then
    break
  fi
  sleep 1
done
nodes=$(docker service ps "$service" --filter desired-state=running --format '{{.Node}} {{.CurrentState}}' 2>/dev/null | awk '$2 == "Running" {print $1}' | sort -u | wc -l)
running=$(docker service ps "$service" --filter desired-state=running --format '{{.CurrentState}}' 2>/dev/null | awk '$1 == "Running" {n++} END {print n+0}')
if test "$nodes" -lt "$NODES_MIN"; then
  docker service ps "$service" --no-trunc || true
  echo "STACK_SMOKE_NOT_ENOUGH_NODES nodes=$nodes running=$running min=$NODES_MIN ready=$active_nodes"
  exit 1
fi
trap - EXIT
cleanup
echo "STACK_SMOKE_OK nodes=$nodes running=$running ready=$active_nodes image=$IMAGE"
