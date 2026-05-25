#!/bin/sh
set -eu
GO_BIN=${GO_BIN:-/tmp/cs-storage-go/go/bin/go}
WORKDIR=
SMOKE=${SMOKE:-/tmp/cs-chattr-guard-smoke}
ROOT="$SMOKE/vols"
SOCK="$SMOKE/daemon.sock"
cd "$WORKDIR"
"$GO_BIN" build -buildvcs=false -o /tmp/cs-storage-daemon ./cmd/cs-storage-daemon
if test -d "$ROOT"; then
  chattr -i "$ROOT" 2>/dev/null || true
fi
rm -rf "$SMOKE"
mkdir -p "$SMOKE"
CS_DAEMON_SOCKET="$SOCK" \
CS_ROOT_DIR="$ROOT" \
CS_STATE_PATH="$ROOT/.state/volumes.json" \
CS_ENABLE_CHATTR=true \
/tmp/cs-storage-daemon > "$SMOKE/daemon.log" 2>&1 &
dp=$!
cleanup() {
  kill "$dp" 2>/dev/null || true
  if test -d "$ROOT"; then
    chattr -i "$ROOT" 2>/dev/null || true
  fi
  rm -rf "$SMOKE"
}
trap cleanup EXIT
for _ in $(seq 1 50); do
  test -S "$SOCK" && curl --unix-socket "$SOCK" -fsS http://unix/healthz >/dev/null 2>&1 && break
  sleep 0.1
done
curl --unix-socket "$SOCK" -fsS http://unix/healthz >/dev/null
resp=$(curl --unix-socket "$SOCK" -fsS -X POST http://unix/v1/create -H 'Content-Type: application/json' -d '{"name":"guard","opts":{"cs.crypt":"false"}}')
printf '%s' "$resp" | grep -q '"error":""\|"mountpoint"'
if mkdir "$ROOT/docker-race" 2>"$SMOKE/mkdir.err"; then
  echo CHATTR_GUARD_UNEXPECTED_CREATE
  exit 1
fi
trap - EXIT
cleanup
echo CHATTR_GUARD_SMOKE_OK
