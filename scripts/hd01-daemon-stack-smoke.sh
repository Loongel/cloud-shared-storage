#!/bin/sh
set -eu
IMAGE=${IMAGE:-cs-storage:hd01-smoke}
SMOKE=${SMOKE:-/tmp/cs-storage-daemon-stack-smoke}
rm -rf "$SMOKE"
mkdir -p "$SMOKE"
CS_STORAGE_IMAGE="$IMAGE" CS_SERVER_URL=http://127.0.0.1:18080 CS_NODE_SECRET_KEY=dummy CS_GOCRYPTFS_PASSWORD=dummy docker compose -f deploy/stack/cs-storage-daemon-global.yml config > "$SMOKE/compose.yml"
CS_STORAGE_IMAGE="$IMAGE" CS_SERVER_URL=http://127.0.0.1:18080 CS_NODE_SECRET_KEY=dummy CS_GOCRYPTFS_PASSWORD=dummy docker stack config -c deploy/stack/cs-storage-daemon-global.yml > "$SMOKE/stack.yml"
grep -q 'cs-storage-daemon' "$SMOKE/compose.yml"
grep -q 'CS_NODE_ID.*{{.Node.Hostname}}' "$SMOKE/compose.yml"
grep -q 'propagation: rshared' "$SMOKE/compose.yml"
grep -q 'SYS_ADMIN' "$SMOKE/compose.yml"
grep -q '/dev/fuse' "$SMOKE/compose.yml"
grep -q 'mode: global' "$SMOKE/stack.yml"
echo "DAEMON_STACK_SMOKE_OK image=$IMAGE"
