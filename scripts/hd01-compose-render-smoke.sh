#!/bin/sh
set -eu
GO_BIN=${GO_BIN:-/tmp/cs-storage-go/go/bin/go}
WORKDIR=
STACK=${STACK:-cs-storage-render-smoke}
IMAGE=${IMAGE:-busybox:latest}
SMOKE=${SMOKE:-/tmp/cs-storage-render-smoke}
cd "$WORKDIR"
"$GO_BIN" build -buildvcs=false -o /tmp/cs-storage-admin ./cmd/cs-storage-admin
rm -rf "$SMOKE"
mkdir -p "$SMOKE"
cat > "$SMOKE/stack.yml" <<EOF
version: "3.8"
services:
  probe:
    image: $IMAGE
    command: ["sh", "-c", "hostname; sleep 60"]
    deploy:
      replicas: 1
      restart_policy:
        condition: none
volumes:
  data:
    driver: cs-storage
    labels:
      cs.mode: shared
      cs.write: multi
      cs.engine: static
      cs.crypt: "false"
    driver_opts:
      cs.write: single
EOF
/tmp/cs-storage-admin render-compose -in "$SMOKE/stack.yml" -out "$SMOKE/stack.rendered.yml"
grep -q 'driver_opts:' "$SMOKE/stack.rendered.yml"
grep -q 'cs.mode: shared' "$SMOKE/stack.rendered.yml"
grep -q 'cs.write: single' "$SMOKE/stack.rendered.yml"
grep -q 'cs.engine: static' "$SMOKE/stack.rendered.yml"
grep -q 'cs.crypt: "false"' "$SMOKE/stack.rendered.yml"
cat > "$SMOKE/flush.yml" <<EOF
volumes:
  bad:
    labels:
      flush: "true"
EOF
if /tmp/cs-storage-admin render-compose -in "$SMOKE/flush.yml" -out "$SMOKE/flush.rendered.yml" >/tmp/cs-storage-render-flush.log 2>&1; then
  echo RENDER_FLUSH_LABEL_NOT_REJECTED
  exit 1
fi
grep -q 'flush' /tmp/cs-storage-render-flush.log
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
/tmp/cs-storage-admin deploy-stack -in "$SMOKE/stack.yml" -stack "$STACK" -rendered-out "$SMOKE/stack.deploy.yml" >/tmp/cs-storage-deploy-stack.log 2>&1
grep -q 'cs.mode: shared' "$SMOKE/stack.deploy.yml"
grep -q 'cs.write: single' "$SMOKE/stack.deploy.yml"
service="${STACK}_probe"
for _ in $(seq 1 60); do
  running=$(docker service ps "$service" --filter desired-state=running --format '{{.CurrentState}}' 2>/dev/null | awk '$1 == "Running" {n++} END {print n+0}')
  if test "$running" -ge 1; then
    break
  fi
  sleep 1
done
running=$(docker service ps "$service" --filter desired-state=running --format '{{.CurrentState}}' 2>/dev/null | awk '$1 == "Running" {n++} END {print n+0}')
if test "$running" -lt 1; then
  docker service ps "$service" --no-trunc || true
  echo "COMPOSE_RENDER_STACK_NOT_RUNNING running=$running"
  exit 1
fi
trap - EXIT
cleanup
echo COMPOSE_RENDER_SMOKE_OK
echo DEPLOY_STACK_SMOKE_OK
