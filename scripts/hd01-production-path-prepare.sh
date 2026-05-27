#!/bin/sh
set -eu

if test "${CSS_ALLOW_HISTORICAL_SWARM_HOST_HELPER:-}" != "yes"; then
  cat >&2 <<'EOF'
CSS_HISTORICAL_SWARM_HOST_HELPER_DISABLED

This script creates host paths through a Swarm global helper. That cross-node
host-mutation path is disabled by default. The cs-storage deb package and local
role installers now own host path creation on each node.
EOF
  exit 2
fi

STACK=${STACK:-cs-storage-production-path-prepare}
IMAGE=${IMAGE:-alpine:3.20}
SMOKE=${SMOKE:-/tmp/cs-storage-production-path-prepare}
NODES_MIN=${NODES_MIN:-}
VOLUME_ROOT=${VOLUME_ROOT:-/mnt/cs_storage/vols}
LOG_ROOT=${LOG_ROOT:-/var/log/cs-storage}
VOLUME_MODE=${VOLUME_MODE:-700}
LOG_MODE=${LOG_MODE:-755}

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
  echo "PRODUCTION_PATH_PREPARE_NOT_ENOUGH_NODES ready=$active_nodes min=$NODES_MIN"
  exit 1
fi

case "$VOLUME_ROOT" in
  /mnt/cs_storage/vols|/mnt/cs_storage/vols/*) ;;
  *) echo "REFUSE_VOLUME_ROOT path=$VOLUME_ROOT"; exit 1 ;;
esac
case "$LOG_ROOT" in
  /var/log/cs-storage|/var/log/cs-storage/*) ;;
  *) echo "REFUSE_LOG_ROOT path=$LOG_ROOT"; exit 1 ;;
esac

cat > "$SMOKE/stack.yml" <<STACK_EOF
version: "3.8"
services:
  prepare:
    image: $IMAGE
    command:
      - /bin/sh
      - -c
      - |
        set -eu
        node=\$\$(cat /host/etc/hostname 2>/dev/null || hostname)
        mkdir -p /host$VOLUME_ROOT /host$LOG_ROOT
        chmod $VOLUME_MODE /host$VOLUME_ROOT
        chmod $LOG_MODE /host$LOG_ROOT
        test -d /host$VOLUME_ROOT
        test -d /host$LOG_ROOT
        echo "PRODUCTION_PATH_PREPARE_NODE_OK \$\$node volume_root=$VOLUME_ROOT log_root=$LOG_ROOT"
    volumes:
      - type: bind
        source: /
        target: /host
    deploy:
      mode: global
      restart_policy:
        condition: none
STACK_EOF

docker stack deploy -c "$SMOKE/stack.yml" "$STACK" >/dev/null
service="${STACK}_prepare"
completed=0
failed=0
for _ in $(seq 1 120); do
  docker service logs --raw "$service" > "$SMOKE/live-logs.txt" 2>/dev/null || true
  docker service ps "$service" --no-trunc --format '{{.Node}}|{{.CurrentState}}|{{.Error}}' > "$SMOKE/service-ps.txt" 2>/dev/null || true
  ok=$(awk '$1 == "PRODUCTION_PATH_PREPARE_NODE_OK" {n++} END {print n+0}' "$SMOKE/live-logs.txt")
  completed=$(awk -F'|' '$2 ~ /^Complete/ {print $1}' "$SMOKE/service-ps.txt" | sort -u | wc -l | tr -d ' ')
  failed=$(awk -F'|' '$2 ~ /^Failed|^Rejected/ || $3 != "" {n++} END {print n+0}' "$SMOKE/service-ps.txt")
  if test "$failed" -gt 0 || test "$ok" -ge "$NODES_MIN" || test "$completed" -ge "$NODES_MIN"; then
    break
  fi
  sleep 1
done

docker service logs --raw "$service" > "$SMOKE/logs.txt" 2>&1 || true
docker service ps "$service" --no-trunc --format '{{.Node}}|{{.CurrentState}}|{{.Error}}' > "$SMOKE/service-ps.txt" 2>/dev/null || true
cat "$SMOKE/logs.txt"
ok=$(awk '$1 == "PRODUCTION_PATH_PREPARE_NODE_OK" {n++} END {print n+0}' "$SMOKE/logs.txt")
completed=$(awk -F'|' '$2 ~ /^Complete/ {print $1}' "$SMOKE/service-ps.txt" | sort -u | wc -l | tr -d ' ')
failed=$(awk -F'|' '$2 ~ /^Failed|^Rejected/ || $3 != "" {n++} END {print n+0}' "$SMOKE/service-ps.txt")
if test "$failed" -gt 0 || { test "$ok" -lt "$NODES_MIN" && test "$completed" -lt "$NODES_MIN"; }; then
  docker service ps "$service" --no-trunc || true
  echo "PRODUCTION_PATH_PREPARE_NOT_READY ok=$ok completed=$completed failed=$failed min=$NODES_MIN ready=$active_nodes image=$IMAGE"
  exit 1
fi

trap - EXIT
cleanup

if test "$ok" -lt "$NODES_MIN"; then
  echo "PRODUCTION_PATH_PREPARE_LOGS_PARTIAL ok_logs=$ok completed=$completed min=$NODES_MIN"
  ok=$completed
fi
echo "PRODUCTION_PATH_PREPARE_OK nodes=$ok ready=$active_nodes image=$IMAGE volume_root=$VOLUME_ROOT log_root=$LOG_ROOT"
