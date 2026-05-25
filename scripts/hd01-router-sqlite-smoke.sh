#!/bin/sh
set -eu
GO_BIN=${GO_BIN:-/tmp/cs-storage-go/go/bin/go}
WORKDIR=${WORKDIR:-/tmp/cs-storage-work-current}
SMOKE=${SMOKE:-/tmp/cs-router-sqlite-smoke}
IMAGE=${IMAGE:-cs-storage:hd01-smoke}
WRITERS=${WRITERS:-4}
ROWS_PER_WRITER=${ROWS_PER_WRITER:-100}
EXPECTED_ROWS=$((WRITERS * ROWS_PER_WRITER))
cd "$WORKDIR"
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  docker build -t "$IMAGE" . >/dev/null
fi
"$GO_BIN" build -buildvcs=false -o /tmp/cs-storage-router ./cmd/cs-storage-router
fusermount3 -u "$SMOKE/mnt" 2>/dev/null || umount -l "$SMOKE/mnt" 2>/dev/null || true
rm -rf "$SMOKE"
mkdir -p "$SMOKE/mnt" "$SMOKE/litefs" "$SMOKE/gluster"
cleanup() {
  fusermount3 -u "$SMOKE/mnt" 2>/dev/null || umount -l "$SMOKE/mnt" 2>/dev/null || true
  if test -n "${pid:-}"; then
    wait "$pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT
/tmp/cs-storage-router -mountpoint "$SMOKE/mnt" -litefs "$SMOKE/litefs" -gluster "$SMOKE/gluster" > "$SMOKE/router.log" 2>&1 &
pid=$!
for _ in $(seq 1 50); do
  grep -q " $SMOKE/mnt " /proc/self/mountinfo && break
  sleep 0.1
done
grep -q " $SMOKE/mnt " /proc/self/mountinfo
mkdir -p "$SMOKE/mnt/data"
docker run --rm --entrypoint sqlite3 -v "$SMOKE/mnt:/mnt" "$IMAGE" /mnt/data/main.db \
  "PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000; CREATE TABLE IF NOT EXISTS events(writer INTEGER, n INTEGER, value TEXT);" > "$SMOKE/init.out"
writer_pids=""
for writer in $(seq 1 "$WRITERS"); do
  docker run --rm --entrypoint sh -e WRITER="$writer" -e ROWS_PER_WRITER="$ROWS_PER_WRITER" -v "$SMOKE/mnt:/mnt" "$IMAGE" -c '
    n=1
    while test "$n" -le "$ROWS_PER_WRITER"; do
      sqlite3 /mnt/data/main.db "PRAGMA busy_timeout=5000; INSERT INTO events(writer,n,value) VALUES($WRITER,$n,'"'"'writer-'"'"'||$WRITER||'"'"'-'"'"'||$n);" >/dev/null
      n=$((n + 1))
    done
  ' &
  writer_pids="$writer_pids $!"
done
for writer_pid in $writer_pids; do
  wait "$writer_pid"
done
integrity=$(docker run --rm --entrypoint sqlite3 -v "$SMOKE/mnt:/mnt" "$IMAGE" /mnt/data/main.db "PRAGMA integrity_check;")
if test "$integrity" != "ok"; then
  echo "SQLITE_INTEGRITY_FAILED result=$integrity"
  exit 1
fi
count=$(docker run --rm --entrypoint sqlite3 -v "$SMOKE/mnt:/mnt" "$IMAGE" /mnt/data/main.db "SELECT COUNT(*) FROM events;")
if test "$count" != "$EXPECTED_ROWS"; then
  echo "SQLITE_COUNT_MISMATCH count=$count"
  exit 1
fi
printf after > "$SMOKE/mnt/data/after.txt"
test -f "$SMOKE/litefs/data/main.db"
test -f "$SMOKE/litefs/data/after.txt"
test ! -e "$SMOKE/gluster/data/main.db"
test ! -e "$SMOKE/gluster/data/after.txt"
trap - EXIT
cleanup
echo "ROUTER_SQLITE_SMOKE_OK rows=$count writers=$WRITERS rows_per_writer=$ROWS_PER_WRITER integrity=$integrity image=$IMAGE"
