#!/bin/sh
set -eu
GO_BIN=${GO_BIN:-/tmp/cs-storage-go/go/bin/go}
WORKDIR=
cd "$WORKDIR"
"$GO_BIN" build -buildvcs=false -o /tmp/cs-storage-daemon ./cmd/cs-storage-daemon
"$GO_BIN" build -buildvcs=false -o /tmp/cs-storage-plugin ./cmd/cs-storage-plugin
timeout 10s docker volume rm cs-smoke-vol >/dev/null 2>&1 || true
timeout 10s docker volume rm cs-smoke-flush-label >/dev/null 2>&1 || true
rm -f /run/docker/plugins/cs-storage.sock /tmp/cs-storage-smoke.sock
rm -rf /tmp/cs-storage-docker-smoke
mkdir -p /run/docker/plugins
CS_DAEMON_SOCKET=/tmp/cs-storage-smoke.sock \
CS_ROOT_DIR=/tmp/cs-storage-docker-smoke/vols \
CS_STATE_PATH=/tmp/cs-storage-docker-smoke/state/volumes.json \
/tmp/cs-storage-daemon > /tmp/cs-storage-docker-smoke-daemon.log 2>&1 &
dp=$!
for _ in $(seq 1 50); do
  test -S /tmp/cs-storage-smoke.sock && break
  sleep 0.1
done
test -S /tmp/cs-storage-smoke.sock
CS_PLUGIN_SOCKET=/run/docker/plugins/cs-storage.sock \
CS_DAEMON_SOCKET=/tmp/cs-storage-smoke.sock \
/tmp/cs-storage-plugin > /tmp/cs-storage-docker-smoke-plugin.log 2>&1 &
pp=$!
cleanup() {
  timeout 10s docker volume rm cs-smoke-vol >/dev/null 2>&1 || true
  timeout 10s docker volume rm cs-smoke-flush-label >/dev/null 2>&1 || true
  kill "$pp" "$dp" 2>/dev/null || true
  rm -f /run/docker/plugins/cs-storage.sock /tmp/cs-storage-smoke.sock
}
trap cleanup EXIT
for _ in $(seq 1 50); do
  test -S /run/docker/plugins/cs-storage.sock && break
  sleep 0.1
done
test -S /run/docker/plugins/cs-storage.sock
docker volume create -d cs-storage -o cs.crypt=false cs-smoke-vol
docker volume inspect cs-smoke-vol >/tmp/cs-storage-docker-smoke-inspect.json
timeout 10s docker volume rm cs-smoke-vol
trap - EXIT
cleanup

rm -f /run/docker/plugins/cs-storage-failfast.sock /tmp/cs-storage-missing-daemon.sock
timeout 10s docker volume rm cs-smoke-failfast >/dev/null 2>&1 || true
RACE_ROOT=/tmp/cs-storage-docker-failfast-root
rm -rf "$RACE_ROOT"
CS_PLUGIN_SOCKET=/run/docker/plugins/cs-storage-failfast.sock \
CS_DAEMON_SOCKET=/tmp/cs-storage-missing-daemon.sock \
CS_PLUGIN_TIMEOUT=2s \
/tmp/cs-storage-plugin > /tmp/cs-storage-docker-failfast-plugin.log 2>&1 &
fp=$!
cleanup_failfast() {
  timeout 10s docker volume rm cs-smoke-failfast >/dev/null 2>&1 || true
  rm -rf "$RACE_ROOT"
  kill "$fp" 2>/dev/null || true
  rm -f /run/docker/plugins/cs-storage-failfast.sock /tmp/cs-storage-missing-daemon.sock
}
trap cleanup_failfast EXIT
for _ in $(seq 1 50); do
  test -S /run/docker/plugins/cs-storage-failfast.sock && break
  sleep 0.1
done
test -S /run/docker/plugins/cs-storage-failfast.sock
start=$(date +%s)
if timeout 8 docker volume create -d cs-storage-failfast cs-smoke-failfast > /tmp/cs-storage-docker-failfast.out 2>&1; then
  cat /tmp/cs-storage-docker-failfast.out
  echo "expected docker volume create to fail when daemon socket is missing" >&2
  exit 1
fi
elapsed=$(( $(date +%s) - start ))
grep -q "daemon unavailable" /tmp/cs-storage-docker-failfast.out
if [ "$elapsed" -gt 7 ]; then
  cat /tmp/cs-storage-docker-failfast.out
  echo "daemon unavailable response took too long: ${elapsed}s" >&2
  exit 1
fi
if test -e "$RACE_ROOT/cs-smoke-failfast" || test -e "$RACE_ROOT"; then
  find "$RACE_ROOT" -maxdepth 3 -print 2>/dev/null || true
  echo "daemon-missing failfast path created unexpected bare root data" >&2
  exit 1
fi
if timeout 8 docker run --rm --volume-driver cs-storage-failfast -v cs-smoke-failfast:/data alpine:3.20 true > /tmp/cs-storage-docker-failfast-run.out 2>&1; then
  cat /tmp/cs-storage-docker-failfast-run.out
  echo "expected docker run to fail when daemon socket is missing" >&2
  exit 1
fi
grep -q "daemon unavailable" /tmp/cs-storage-docker-failfast-run.out
if test -e "$RACE_ROOT/cs-smoke-failfast" || test -e "$RACE_ROOT"; then
  find "$RACE_ROOT" -maxdepth 3 -print 2>/dev/null || true
  echo "daemon-missing docker run created unexpected bare root data" >&2
  exit 1
fi
trap - EXIT
cleanup_failfast
echo DOCKER_PLUGIN_FAILFAST_SMOKE_OK elapsed=${elapsed}s
echo DOCKER_PLUGIN_SMOKE_OK
