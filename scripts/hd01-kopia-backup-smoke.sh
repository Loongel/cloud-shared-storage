#!/bin/sh
set -eu

GO_BIN=${GO_BIN:-/tmp/cs-storage-go/go/bin/go}
WORKDIR=${WORKDIR:-/tmp/cs-storage-work-current}
IMAGE=${IMAGE:-cs-storage:hd01-smoke}
SMOKE=${SMOKE:-/tmp/cs-storage-kopia-backup-smoke}
PASS=${PASS:-cs-storage-kopia-smoke-pass}
VOLUME=${VOLUME:-kopia-backup-vol}

ROOT="$SMOKE/vols"
SOCK="$SMOKE/daemon.sock"
REPO="$SMOKE/repo"
CONFIG="$SMOKE/kopia.repository.config"
RESTORE="$SMOKE/restore"
PAYLOAD='cs-storage kopia backup smoke payload'

rm -rf "$SMOKE"
mkdir -p "$SMOKE/bin" "$REPO"

cd "$WORKDIR"
"$GO_BIN" build -buildvcs=false -o "$SMOKE/bin/cs-storage-daemon" ./cmd/cs-storage-daemon
cid=$(docker create --entrypoint sh "$IMAGE" -c true)
docker cp "$cid:/usr/local/bin/kopia" "$SMOKE/bin/kopia"
docker rm "$cid" >/dev/null
chmod +x "$SMOKE/bin/kopia"

KOPIA_CHECK_FOR_UPDATES=false \
KOPIA_PASSWORD="$PASS" \
"$SMOKE/bin/kopia" --config-file "$CONFIG" repository create filesystem --path "$REPO" --disable-file-logging >/"$SMOKE/kopia-create.log" 2>&1

CS_DAEMON_SOCKET="$SOCK" \
CS_ROOT_DIR="$ROOT" \
CS_STATE_PATH="$ROOT/.state/volumes.json" \
CS_AUDIT_LOG="$SMOKE/audit.jsonl" \
CS_ENABLE_CHATTR=false \
CS_KOPIA_BINARY="$SMOKE/bin/kopia" \
CS_KOPIA_CONFIG_PATH="$CONFIG" \
CS_KOPIA_PASSWORD="$PASS" \
CS_KOPIA_SNAPSHOT_INTERVAL=1s \
CS_KOPIA_POLICY_ARGS="--keep-latest=24 --keep-daily=7" \
KOPIA_CHECK_FOR_UPDATES=false \
"$SMOKE/bin/cs-storage-daemon" > "$SMOKE/daemon.log" 2>&1 &
dp=$!
cleanup() {
  kill "$dp" 2>/dev/null || true
  wait "$dp" 2>/dev/null || true
  if test "${KEEP_SMOKE:-0}" != 1; then
    rm -rf "$SMOKE"
  fi
}
trap cleanup EXIT

for _ in $(seq 1 100); do
  test -S "$SOCK" && curl --unix-socket "$SOCK" -fsS http://unix/healthz >/dev/null 2>&1 && break
  sleep 0.1
done
curl --unix-socket "$SOCK" -fsS http://unix/healthz >/dev/null

create_resp=$(curl --unix-socket "$SOCK" -fsS -X POST http://unix/v1/create -H 'Content-Type: application/json' -d '{"name":"'"$VOLUME"'","opts":{"cs.crypt":"false","cs.backup":"true"}}')
printf '%s' "$create_resp" > "$SMOKE/create.json"
printf '%s' "$create_resp" | grep -q '"mountpoint"'
MOUNT="$ROOT/$VOLUME/mount"
printf '%s\n' "$PAYLOAD" > "$MOUNT/payload.txt"
for _ in $(seq 1 60); do
  if grep -q 'Created snapshot' "$ROOT/$VOLUME/logs/kopia.log" 2>/dev/null; then
    break
  fi
  sleep 1
done
if ! grep -q 'Created snapshot' "$ROOT/$VOLUME/logs/kopia.log" 2>/dev/null; then
  echo KOPIA_PERIODIC_SNAPSHOT_MISSING
  cat "$ROOT/$VOLUME/logs/kopia.log" 2>/dev/null || true
  exit 1
fi

remove_resp=$(curl --unix-socket "$SOCK" -fsS -X POST http://unix/v1/remove -H 'Content-Type: application/json' -d '{"name":"'"$VOLUME"'","opts":{"cs.crypt":"false","cs.backup":"true"}}')
printf '%s' "$remove_resp" > "$SMOKE/remove.json"
if printf '%s' "$remove_resp" | grep -q '"error":"[^"]'; then
  cat "$SMOKE/remove.json"
  cat "$ROOT/$VOLUME/logs/kopia.log" 2>/dev/null || true
  exit 1
fi

test -s "$ROOT/$VOLUME/logs/kopia.log"
grep -q 'Created snapshot' "$ROOT/$VOLUME/logs/kopia.log"
grep -q 'kopia policy updated' "$ROOT/$VOLUME/logs/kopia.log"
KOPIA_CHECK_FOR_UPDATES=false \
KOPIA_PASSWORD="$PASS" \
"$SMOKE/bin/kopia" --config-file "$CONFIG" restore --snapshot-time latest "$MOUNT" "$RESTORE" --disable-file-logging >/"$SMOKE/kopia-restore.log" 2>&1
cmp "$MOUNT/payload.txt" "$RESTORE/payload.txt"
KOPIA_CHECK_FOR_UPDATES=false \
KOPIA_PASSWORD="$PASS" \
"$SMOKE/bin/kopia" --config-file "$CONFIG" snapshot list --all --json --disable-file-logging > "$SMOKE/snapshots.json"
grep -q 'cs-storage:'"$VOLUME" "$SMOKE/snapshots.json"

echo "KOPIA_BACKUP_SMOKE_OK volume=$VOLUME image=$IMAGE repo=filesystem periodic=ok policy=ok snapshots=1"
trap - EXIT
cleanup
