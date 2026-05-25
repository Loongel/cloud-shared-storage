#!/bin/sh
set -eu
STACK=${STACK:-cs-storage-daemon-global-run-smoke}
IMAGE=${IMAGE:-cs-storage:hd01-smoke}
SMOKE=${SMOKE:-/tmp/cs-storage-daemon-global-run-smoke}
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
  echo "DAEMON_GLOBAL_NOT_ENOUGH_NODES ready=$active_nodes min=$NODES_MIN"
  exit 1
fi
cat > "$SMOKE/stack.yml" <<EOF
version: "3.8"
services:
  daemon:
    image: $IMAGE
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        set -eu
        rm -f /tmp/cs-storage-smoke.sock
        CS_DAEMON_SOCKET=/tmp/cs-storage-smoke.sock \
        CS_ROOT_DIR=/tmp/cs-storage-smoke/vols \
        CS_STATE_PATH=/tmp/cs-storage-smoke/state/volumes.json \
        CS_AUDIT_LOG=/tmp/cs-storage-smoke/state/audit.jsonl \
        CS_ENABLE_CHATTR=false \
        CS_RECOVER_MOUNTS=false \
        /usr/local/bin/cs-storage-daemon &
        pid=\$!
        sleep 5
        if test -S /tmp/cs-storage-smoke.sock; then
          echo DAEMON_GLOBAL_READY socket=/tmp/cs-storage-smoke.sock
          wait \$pid
          exit 0
        fi
        echo DAEMON_GLOBAL_SOCKET_MISSING >&2
        kill \$pid 2>/dev/null || true
        exit 1
    deploy:
      mode: global
      restart_policy:
        condition: none
EOF
docker stack deploy -c "$SMOKE/stack.yml" "$STACK" >/dev/null
service="${STACK}_daemon"
for _ in $(seq 1 120); do
  running_nodes=$(docker service ps "$service" --filter desired-state=running --format '{{.Node}} {{.CurrentState}}' 2>/dev/null | awk '$2 == "Running" {print $1}' | sort -u | wc -l)
  ready=$(docker service logs --raw "$service" 2>/dev/null | awk '$1 == "DAEMON_GLOBAL_READY" {n++} END {print n+0}')
  failed=$(docker service ps "$service" --format '{{.CurrentState}}' 2>/dev/null | awk '$1 == "Failed" || $1 == "Rejected" {n++} END {print n+0}')
  if test "$running_nodes" -ge "$NODES_MIN" && { test "$ready" -ge "$NODES_MIN" || { test "$ready" -gt 0 && test "$failed" -eq 0; }; }; then
    break
  fi
  sleep 1
done
logs="$SMOKE/logs.txt"
docker service logs --raw "$service" > "$logs" 2>&1 || true
cat "$logs"
running_nodes=$(docker service ps "$service" --filter desired-state=running --format '{{.Node}} {{.CurrentState}}' 2>/dev/null | awk '$2 == "Running" {print $1}' | sort -u | wc -l)
ready=$(awk '$1 == "DAEMON_GLOBAL_READY" {n++} END {print n+0}' "$logs")
failed=$(docker service ps "$service" --format '{{.CurrentState}}' 2>/dev/null | awk '$1 == "Failed" || $1 == "Rejected" {n++} END {print n+0}')
if test "$running_nodes" -lt "$NODES_MIN" || test "$failed" -gt 0 || test "$ready" -eq 0; then
  docker service ps "$service" --no-trunc || true
  echo "DAEMON_GLOBAL_RUN_SMOKE_NOT_READY running=$running_nodes ready_logs=$ready failed=$failed min=$NODES_MIN swarm_ready=$active_nodes image=$IMAGE"
  exit 1
fi
if test "$ready" -lt "$NODES_MIN"; then
  echo "DAEMON_GLOBAL_LOGS_PARTIAL ready_logs=$ready running=$running_nodes min=$NODES_MIN image=$IMAGE"
fi
trap - EXIT
cleanup
echo "DAEMON_GLOBAL_RUN_SMOKE_OK nodes=$running_nodes ready_logs=$ready swarm_ready=$active_nodes image=$IMAGE"
