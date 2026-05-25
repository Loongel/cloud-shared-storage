#!/bin/sh
set -eu
GO_BIN=${GO_BIN:-/tmp/cs-storage-go/go/bin/go}
WORKDIR=
SMOKE=${SMOKE:-/tmp/cs-router-smoke}
cd "$WORKDIR"
"$GO_BIN" build -buildvcs=false -o /tmp/cs-storage-router ./cmd/cs-storage-router
fusermount3 -u "$SMOKE/mnt" 2>/dev/null || umount -l "$SMOKE/mnt" 2>/dev/null || true
rm -rf "$SMOKE"
mkdir -p "$SMOKE/mnt" "$SMOKE/litefs" "$SMOKE/gluster"
/tmp/cs-storage-router -mountpoint "$SMOKE/mnt" -litefs "$SMOKE/litefs" -gluster "$SMOKE/gluster" > "$SMOKE/router.log" 2>&1 &
pid=$!
for _ in $(seq 1 50); do
  grep -q " $SMOKE/mnt " /proc/self/mountinfo && break
  sleep 0.1
done
grep -q " $SMOKE/mnt " /proc/self/mountinfo
printf cfg > "$SMOKE/mnt/config.yml"
mkdir -p "$SMOKE/mnt/data"
printf db > "$SMOKE/mnt/data/main.db"
printf aux > "$SMOKE/mnt/data/other.txt"
test -f "$SMOKE/gluster/config.yml"
test -f "$SMOKE/litefs/data/main.db"
test -f "$SMOKE/litefs/data/other.txt"
fusermount3 -u "$SMOKE/mnt"
wait "$pid" || true
echo ROUTER_SMOKE_OK
