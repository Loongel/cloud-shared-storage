#!/bin/sh
set -eu

STACK=${STACK:-cs-storage-swarm-fuse-device-smoke}
IMAGE=${IMAGE:-alpine:3.20}
SMOKE=${SMOKE:-/tmp/cs-storage-swarm-fuse-device-smoke}
NODES_MIN=${NODES_MIN:-}
STRICT=${STRICT:-0}

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
  echo "SWARM_FUSE_DEVICE_NOT_ENOUGH_NODES ready=$active_nodes min=$NODES_MIN"
  exit 1
fi

cat > "$SMOKE/stack.yml" <<STACK_EOF
version: "3.8"
services:
  probe:
    image: $IMAGE
    command:
      - /bin/sh
      - -c
      - |
        set -eu
        node=\$\$(cat /etc/hostname 2>/dev/null || hostname)
        if test ! -c /dev/fuse; then
          echo "SWARM_FUSE_DEVICE_ISSUE \$\$node missing_char_device=/dev/fuse"
          sleep 300
          exit 0
        fi
        if head -c 0 /dev/fuse >/dev/null 2>/tmp/fuse.err; then
          echo "SWARM_FUSE_DEVICE_NODE_OK \$\$node"
        else
          err=\$\$(tr '\n' ' ' < /tmp/fuse.err | sed 's/[[:space:]]\{1,\}/ /g')
          echo "SWARM_FUSE_DEVICE_ISSUE \$\$node open_failed=\$\$err"
        fi
        sleep 300
    cap_add:
      - SYS_ADMIN
    devices:
      - /dev/fuse:/dev/fuse
    deploy:
      mode: global
      restart_policy:
        condition: none
STACK_EOF

docker stack deploy -c "$SMOKE/stack.yml" "$STACK" > "$SMOKE/deploy.out" 2>&1 || {
  cat "$SMOKE/deploy.out"
  exit 1
}
cat "$SMOKE/deploy.out"
service="${STACK}_probe"
for _ in $(seq 1 120); do
  seen=$(docker service logs --raw "$service" 2>/dev/null | awk '$1 ~ /^SWARM_FUSE_DEVICE_/ {n++} END {print n+0}')
  if test "$seen" -ge "$NODES_MIN"; then
    break
  fi
  sleep 1
done

docker service logs --raw "$service" > "$SMOKE/logs.txt" 2>&1 || true
cat "$SMOKE/logs.txt"
ok=$(awk '$1 == "SWARM_FUSE_DEVICE_NODE_OK" {n++} END {print n+0}' "$SMOKE/logs.txt")
issues=$(awk '$1 == "SWARM_FUSE_DEVICE_ISSUE" {n++} END {print n+0}' "$SMOKE/logs.txt")
if test "$ok" -lt "$NODES_MIN"; then
  docker service ps "$service" --no-trunc || true
  trap - EXIT
  cleanup
  echo "SWARM_FUSE_DEVICE_SMOKE_ISSUES ok=$ok issues=$issues nodes=$((ok + issues)) ready=$active_nodes image=$IMAGE"
  if test "$STRICT" = "1"; then
    exit 1
  fi
  exit 0
fi

trap - EXIT
cleanup

echo "SWARM_FUSE_DEVICE_SMOKE_OK nodes=$ok ready=$active_nodes image=$IMAGE"
