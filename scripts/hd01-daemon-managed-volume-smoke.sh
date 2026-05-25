#!/bin/sh
set -eu

GO_BIN=${GO_BIN:-/tmp/cs-storage-go/go/bin/go}
GOFMT_BIN=${GOFMT_BIN:-$(dirname "$GO_BIN")/gofmt}
WORKDIR=${WORKDIR:-/tmp/cs-storage-work-current}
RUN_ID=${RUN_ID:-$$}
SMOKE=${SMOKE:-/tmp/cs-storage-daemon-managed-volume-smoke-$RUN_ID}
DRIVER=${DRIVER:-cs-storage-managed-volume-smoke-$RUN_ID}
VOLUME=${VOLUME:-cs-managed-volume-smoke-vol-$RUN_ID}
DAEMON_SOCKET=${DAEMON_SOCKET:-/run/cs-storage-managed-volume-smoke-$RUN_ID.sock}
PLUGIN_SOCKET=${PLUGIN_SOCKET:-/run/docker/plugins/cs-storage-managed-volume-smoke-$RUN_ID.sock}
ROOT_DIR=${ROOT_DIR:-/mnt/cs_storage/vols/.cs-managed-volume-smoke-$RUN_ID}
AUDIT_LOG=${AUDIT_LOG:-/var/log/cs-storage/managed-volume-smoke-$RUN_ID-audit.jsonl}
LITEFS_PORT=${LITEFS_PORT:-$((20420 + ($$ % 1000)))}
APP_IMAGE=${APP_IMAGE:-cs-storage:hd01-smoke}
RUNTIME_IMAGE=${RUNTIME_IMAGE:-cs-storage:hd01-smoke}
LITEFS_BIN=${LITEFS_BIN:-}

case "$DRIVER" in
  cs-storage-managed-volume-smoke*) ;;
  *) echo "REFUSE_DRIVER name=$DRIVER"; exit 1 ;;
esac
case "$DAEMON_SOCKET" in
  /run/cs-storage-managed-volume-smoke*.sock) ;;
  *) echo "REFUSE_DAEMON_SOCKET path=$DAEMON_SOCKET"; exit 1 ;;
esac
case "$PLUGIN_SOCKET" in
  /run/docker/plugins/cs-storage-managed-volume-smoke*.sock) ;;
  *) echo "REFUSE_PLUGIN_SOCKET path=$PLUGIN_SOCKET"; exit 1 ;;
esac
case "$ROOT_DIR" in
  /mnt/cs_storage/vols/.cs-managed-volume-smoke*) ;;
  *) echo "REFUSE_ROOT_DIR path=$ROOT_DIR"; exit 1 ;;
esac
case "$AUDIT_LOG" in
  /var/log/cs-storage/managed-volume-smoke*) ;;
  *) echo "REFUSE_AUDIT_LOG path=$AUDIT_LOG"; exit 1 ;;
esac

rm -rf "$SMOKE" "$ROOT_DIR"
rm -f "$AUDIT_LOG"
mkdir -p "$SMOKE/bin" "$ROOT_DIR" /run/docker/plugins /var/log/cs-storage

if test -z "$LITEFS_BIN"; then
  if command -v litefs >/dev/null 2>&1; then
    LITEFS_BIN=$(command -v litefs)
  else
    cid=$(docker create "$RUNTIME_IMAGE")
    copied=0
    for candidate in /usr/local/bin/litefs /usr/bin/litefs /bin/litefs; do
      if docker cp "$cid:$candidate" "$SMOKE/bin/litefs" >/dev/null 2>&1; then
        copied=1
        break
      fi
    done
    docker rm "$cid" >/dev/null
    if test "$copied" != 1; then
      echo "MANAGED_VOLUME_SMOKE_PREREQ_MISSING tool=litefs image=$RUNTIME_IMAGE"
      exit 1
    fi
    chmod 700 "$SMOKE/bin/litefs"
    LITEFS_BIN="$SMOKE/bin/litefs"
  fi
fi
if ! command -v fusermount3 >/dev/null 2>&1 && ! command -v fusermount >/dev/null 2>&1; then
  echo "MANAGED_VOLUME_SMOKE_PREREQ_MISSING tool=fusermount"
  exit 1
fi
if test ! -c /dev/fuse; then
  echo "MANAGED_VOLUME_SMOKE_PREREQ_MISSING path=/dev/fuse"
  exit 1
fi

cd "$WORKDIR"
"$GOFMT_BIN" -w cmd internal
"$GO_BIN" build -buildvcs=false -o "$SMOKE/bin/cs-storage-daemon" ./cmd/cs-storage-daemon
"$GO_BIN" build -buildvcs=false -o "$SMOKE/bin/cs-storage-plugin" ./cmd/cs-storage-plugin

daemon_pid=
plugin_pid=
cleanup() {
  timeout 10s docker volume rm "$VOLUME" >/dev/null 2>&1 || true
  if test -S "$DAEMON_SOCKET" && command -v curl >/dev/null 2>&1; then
    curl -fsS --unix-socket "$DAEMON_SOCKET" -X POST http://cs-storage/v1/remove \
      -H 'Content-Type: application/json' \
      -d "{\"name\":\"$VOLUME\",\"opts\":{\"flush\":\"true\",\"cs.crypt\":\"false\",\"cs.mode\":\"shared\",\"cs.write\":\"multi\",\"cs.engine\":\"sqlite\"}}" >/dev/null 2>&1 || true
  fi
  kill "${plugin_pid:-}" "${daemon_pid:-}" 2>/dev/null || true
  wait "${plugin_pid:-}" "${daemon_pid:-}" 2>/dev/null || true
  rm -f "$PLUGIN_SOCKET" "$DAEMON_SOCKET"
}
trap cleanup EXIT
cleanup
mkdir -p "$ROOT_DIR" /run/docker/plugins /var/log/cs-storage

CS_DAEMON_SOCKET="$DAEMON_SOCKET" \
CS_ROOT_DIR="$ROOT_DIR" \
CS_STATE_PATH="$ROOT_DIR/.state/volumes.json" \
CS_AUDIT_LOG="$AUDIT_LOG" \
CS_ENABLE_CHATTR=false \
CS_RECOVER_MOUNTS=false \
CS_MANAGED_VOLUMES="$VOLUME:cs.crypt=false,cs.mode=shared,cs.write=multi,cs.engine=sqlite" \
CS_LITEFS_BINARY="$LITEFS_BIN" \
CS_LITEFS_HTTP_ADDR="127.0.0.1:$LITEFS_PORT" \
CS_LITEFS_LEASE_TYPE=static \
CS_LITEFS_ADVERTISE_URL="http://127.0.0.1:$LITEFS_PORT" \
CS_LITEFS_CANDIDATE=true \
CS_LITEFS_PROMOTE=true \
"$SMOKE/bin/cs-storage-daemon" > "$SMOKE/daemon.log" 2>&1 &
daemon_pid=$!
for _ in $(seq 1 100); do
  if test -S "$DAEMON_SOCKET"; then
    break
  fi
  sleep 0.1
done
test -S "$DAEMON_SOCKET"

MOUNTPOINT="$ROOT_DIR/$VOLUME/mount"
for _ in $(seq 1 160); do
  if docker run --rm --entrypoint sqlite3 -v "$MOUNTPOINT:/data" "$APP_IMAGE" /data/managed.db "PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS events(source TEXT, n INTEGER); INSERT INTO events VALUES('daemon-managed', 1); SELECT COUNT(*) FROM events;" >/tmp/cs-managed-volume-smoke-sqlite.out 2>/dev/null; then
    break
  fi
  sleep 0.5
done
if ! grep -q '^1$' /tmp/cs-managed-volume-smoke-sqlite.out 2>/dev/null; then
  echo MANAGED_VOLUME_SMOKE_NOT_READY
  echo DAEMON_LOGS
  sed -n '1,180p' "$SMOKE/daemon.log" || true
  find "$ROOT_DIR" -maxdepth 5 -type f -name 'litefs*.log' -print -exec sed -n '1,160p' {} \; 2>/dev/null || true
  exit 1
fi
if ! grep -q '"event":"managed-ensure"' "$AUDIT_LOG" 2>/dev/null; then
  echo MANAGED_VOLUME_SMOKE_AUDIT_MISSING
  sed -n '1,120p' "$AUDIT_LOG" || true
  exit 1
fi

CS_PLUGIN_SOCKET="$PLUGIN_SOCKET" \
CS_DAEMON_SOCKET="$DAEMON_SOCKET" \
CS_PLUGIN_TIMEOUT=30s \
CS_PLUGIN_SCOPE=local \
"$SMOKE/bin/cs-storage-plugin" > "$SMOKE/plugin.log" 2>&1 &
plugin_pid=$!
for _ in $(seq 1 100); do
  if test -S "$PLUGIN_SOCKET"; then
    break
  fi
  sleep 0.1
done
test -S "$PLUGIN_SOCKET"

docker volume create -d "$DRIVER" -o cs.crypt=false -o cs.mode=shared -o cs.write=multi -o cs.engine=sqlite "$VOLUME" >/dev/null
start=$(date +%s)
docker run --rm --entrypoint sqlite3 -v "$VOLUME:/data" "$APP_IMAGE" /data/managed.db "INSERT INTO events VALUES('docker-driver', 2); SELECT COUNT(*) FROM events;" > "$SMOKE/docker-volume.out"
elapsed=$(( $(date +%s) - start ))
if ! grep -q '^2$' "$SMOKE/docker-volume.out"; then
  echo MANAGED_VOLUME_SMOKE_DOCKER_VOLUME_FAILED
  cat "$SMOKE/docker-volume.out" || true
  exit 1
fi
if ! docker run --rm --entrypoint sqlite3 -v "$MOUNTPOINT:/data" "$APP_IMAGE" /data/managed.db "SELECT COUNT(*) FROM events WHERE source='docker-driver';" | grep -q '^1$'; then
  echo MANAGED_VOLUME_SMOKE_NOT_MAINTAINED_AFTER_DOCKER_USE
  exit 1
fi

docker volume rm "$VOLUME" >/dev/null
trap - EXIT
cleanup

echo "DAEMON_MANAGED_VOLUME_SMOKE_OK volume=$VOLUME driver=$DRIVER mountpoint=$MOUNTPOINT elapsed=${elapsed}s rows=2"
