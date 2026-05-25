#!/bin/sh
set -eu

GO_BIN=${GO_BIN:-/tmp/cs-storage-go/go/bin/go}
GOFMT_BIN=${GOFMT_BIN:-$(dirname "$GO_BIN")/gofmt}
WORKDIR=${WORKDIR:-/tmp/cs-storage-work-current}
SMOKE=${SMOKE:-/tmp/cs-storage-host-daemon-webdav-workload-smoke}
DRIVER=${DRIVER:-cs-storage-host-webdav-smoke}
VOLUME=${VOLUME:-cs-host-webdav-smoke-vol}
DAEMON_SOCKET=${DAEMON_SOCKET:-/run/cs-storage-host-webdav-smoke.sock}
PLUGIN_SOCKET=${PLUGIN_SOCKET:-/run/docker/plugins/cs-storage-host-webdav-smoke.sock}
ROOT_DIR=${ROOT_DIR:-/mnt/cs_storage/vols/.cs-host-webdav-smoke}
AUDIT_LOG=${AUDIT_LOG:-/var/log/cs-storage/host-webdav-smoke-audit.jsonl}
SERVER_PORT=${SERVER_PORT:-18122}
SECRET=${SECRET:-cs-host-webdav-smoke-secret}
NODE_ID=${NODE_ID:-$(hostname -s 2>/dev/null || hostname)}
REMOTE_ROOT=${REMOTE_ROOT:-cs-storage-host-webdav-smoke-$(date +%s)-$$}
FILE_NAME=${FILE_NAME:-cs-storage-host-webdav-workload.txt}
VERIFY_TIMEOUT=${VERIFY_TIMEOUT:-180}
APP_IMAGE=${APP_IMAGE:-alpine:3.20}
RCLONE_IMAGE=${RCLONE_IMAGE:-cs-storage:hd01-smoke}
RCLONE_BIN=${RCLONE_BIN:-}

: "${CS_WEBDAV_URL:?CS_WEBDAV_URL is required}"
: "${CS_WEBDAV_USER:?CS_WEBDAV_USER is required}"
: "${CS_WEBDAV_PASSWORD:?CS_WEBDAV_PASSWORD is required}"

case "$DRIVER" in
  cs-storage-host-webdav-smoke*) ;;
  *) echo "REFUSE_DRIVER name=$DRIVER"; exit 1 ;;
esac
case "$DAEMON_SOCKET" in
  /run/cs-storage-host-webdav-smoke*.sock) ;;
  *) echo "REFUSE_DAEMON_SOCKET path=$DAEMON_SOCKET"; exit 1 ;;
esac
case "$PLUGIN_SOCKET" in
  /run/docker/plugins/cs-storage-host-webdav-smoke*.sock) ;;
  *) echo "REFUSE_PLUGIN_SOCKET path=$PLUGIN_SOCKET"; exit 1 ;;
esac
case "$ROOT_DIR" in
  /mnt/cs_storage/vols/.cs-host-webdav-smoke|/mnt/cs_storage/vols/.cs-host-webdav-smoke/*) ;;
  *) echo "REFUSE_ROOT_DIR path=$ROOT_DIR"; exit 1 ;;
esac
case "$AUDIT_LOG" in
  /var/log/cs-storage/host-webdav-smoke*) ;;
  *) echo "REFUSE_AUDIT_LOG path=$AUDIT_LOG"; exit 1 ;;
esac

rm -rf "$SMOKE"
mkdir -p "$SMOKE/bin" "$ROOT_DIR" /run/docker/plugins /var/log/cs-storage

if test -z "$RCLONE_BIN"; then
  if command -v rclone >/dev/null 2>&1; then
    RCLONE_BIN=$(command -v rclone)
    echo "HOST_TOOL_FOUND tool=rclone path=$RCLONE_BIN"
  else
    cid=$(docker create "$RCLONE_IMAGE")
    copied=0
    for candidate in /usr/bin/rclone /usr/local/bin/rclone /bin/rclone; do
      if docker cp "$cid:$candidate" "$SMOKE/bin/rclone" >/dev/null 2>&1; then
        copied=1
        break
      fi
    done
    docker rm "$cid" >/dev/null
    if test "$copied" != "1"; then
      echo "HOST_WEBDAV_PREREQ_MISSING tool=rclone image=$RCLONE_IMAGE"
      exit 1
    fi
    chmod 700 "$SMOKE/bin/rclone"
    RCLONE_BIN="$SMOKE/bin/rclone"
    echo "HOST_TOOL_FOUND tool=rclone source=image path=$RCLONE_BIN image=$RCLONE_IMAGE"
  fi
fi
for tool in fusermount3 fusermount; do
  if command -v "$tool" >/dev/null 2>&1; then
    echo "HOST_TOOL_FOUND tool=$tool path=$(command -v "$tool")"
  fi
done
if ! command -v fusermount3 >/dev/null 2>&1 && ! command -v fusermount >/dev/null 2>&1; then
  echo "HOST_WEBDAV_PREREQ_MISSING tool=fusermount"
  exit 1
fi
if test ! -c /dev/fuse; then
  echo "HOST_WEBDAV_PREREQ_MISSING path=/dev/fuse"
  exit 1
fi

cd "$WORKDIR"
"$GOFMT_BIN" -w cmd internal
"$GO_BIN" build -buildvcs=false -o "$SMOKE/bin/cs-storage-server" ./cmd/cs-storage-server
"$GO_BIN" build -buildvcs=false -o "$SMOKE/bin/cs-storage-daemon" ./cmd/cs-storage-daemon
"$GO_BIN" build -buildvcs=false -o "$SMOKE/bin/cs-storage-plugin" ./cmd/cs-storage-plugin

BASE_URL=${CS_WEBDAV_URL%/}
BASE_HOST=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.urlparse(sys.argv[1]).hostname or "")' "$BASE_URL")
if test -z "$BASE_HOST"; then
  echo INVALID_WEBDAV_URL
  exit 1
fi
NETRC="$SMOKE/curl.netrc"
umask 077
cat > "$NETRC" <<NETRC_EOF
machine $BASE_HOST
login $CS_WEBDAV_USER
password $CS_WEBDAV_PASSWORD
NETRC_EOF
umask 022

mkcol() {
  rel=$1
  code=$(curl -sS -o /dev/null -w '%{http_code}' --netrc-file "$NETRC" -X MKCOL "$BASE_URL/$rel" || true)
  case "$code" in
    200|201|204|405) return 0 ;;
    *) echo "WEBDAV_MKCOL_FAILED rel=$rel http=$code"; return 1 ;;
  esac
}
cleanup_remote() {
  curl -sS -o /dev/null --netrc-file "$NETRC" -X DELETE "$BASE_URL/$REMOTE_ROOT" >/dev/null 2>&1 || true
}
server_pid=
daemon_pid=
plugin_pid=
cleanup() {
  docker volume rm "$VOLUME" >/dev/null 2>&1 || true
  kill "${plugin_pid:-}" "${daemon_pid:-}" "${server_pid:-}" 2>/dev/null || true
  wait "${plugin_pid:-}" "${daemon_pid:-}" "${server_pid:-}" 2>/dev/null || true
  rm -f "$PLUGIN_SOCKET" "$DAEMON_SOCKET" "$NETRC"
  cleanup_remote
}
trap cleanup EXIT

cleanup_remote
mkcol "$REMOTE_ROOT"
mkcol "$REMOTE_ROOT/nodes"
mkcol "$REMOTE_ROOT/nodes/$NODE_ID"

CS_SERVER_ADDR="127.0.0.1:$SERVER_PORT" \
CS_NODE_SECRET_KEY="$SECRET" \
CS_BACKEND_URL="$BASE_URL" \
CS_BACKEND_USER="$CS_WEBDAV_USER" \
CS_BACKEND_PASSWORD="$CS_WEBDAV_PASSWORD" \
CS_SANDBOX_PREFIX="/$REMOTE_ROOT/nodes" \
"$SMOKE/bin/cs-storage-server" > "$SMOKE/server.log" 2>&1 &
server_pid=$!
for _ in $(seq 1 100); do
  if curl -fsS "http://127.0.0.1:$SERVER_PORT/healthz" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
curl -fsS "http://127.0.0.1:$SERVER_PORT/healthz" >/dev/null

rm -f "$DAEMON_SOCKET" "$PLUGIN_SOCKET"
CS_DAEMON_SOCKET="$DAEMON_SOCKET" \
CS_ROOT_DIR="$ROOT_DIR" \
CS_STATE_PATH="$ROOT_DIR/.state/volumes.json" \
CS_AUDIT_LOG="$AUDIT_LOG" \
CS_ENABLE_CHATTR=false \
CS_RECOVER_MOUNTS=false \
CS_SERVER_URL="http://127.0.0.1:$SERVER_PORT" \
CS_RCLONE_ENDPOINT="http://127.0.0.1:$SERVER_PORT" \
CS_NODE_ID="$NODE_ID" \
CS_NODE_SECRET_KEY="$SECRET" \
CS_RCLONE_BINARY="$RCLONE_BIN" \
CS_RCLONE_VFS_CACHE_MODE=writes \
CS_RCLONE_VFS_WRITE_BACK=0s \
CS_RCLONE_EXTRA_ARGS="--allow-other" \
"$SMOKE/bin/cs-storage-daemon" > "$SMOKE/daemon.log" 2>&1 &
daemon_pid=$!
for _ in $(seq 1 100); do
  if test -S "$DAEMON_SOCKET"; then
    break
  fi
  sleep 0.1
done
test -S "$DAEMON_SOCKET"

CS_PLUGIN_SOCKET="$PLUGIN_SOCKET" \
CS_DAEMON_SOCKET="$DAEMON_SOCKET" \
CS_PLUGIN_TIMEOUT=10s \
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

docker volume rm "$VOLUME" >/dev/null 2>&1 || true
docker volume create -d "$DRIVER" -o cs.crypt=false -o cs.mode=private "$VOLUME"
docker run --rm -v "$VOLUME:/data" "$APP_IMAGE" sh -c "printf 'node=%s\n' '$NODE_ID' > /data/$FILE_NAME && sync"
docker volume rm "$VOLUME"
test -s "$AUDIT_LOG"

verified=0
rel="$REMOTE_ROOT/nodes/$NODE_ID/$FILE_NAME"
for _ in $(seq 1 "$VERIFY_TIMEOUT"); do
  code=$(curl -sS -o "$SMOKE/propfind.xml" -w '%{http_code}' --netrc-file "$NETRC" -X PROPFIND -H 'Depth: 0' "$BASE_URL/$rel" || true)
  if test "$code" = "207" || test "$code" = "200"; then
    if grep -q '<[^>]*getcontentlength[^>]*>[1-9][0-9]*<' "$SMOKE/propfind.xml" 2>/dev/null; then
      verified=1
      break
    fi
  fi
  sleep 1
done
if test "$verified" != "1"; then
  echo "HOST_WEBDAV_REMOTE_VERIFY_FAILED node=$NODE_ID remote_root=$REMOTE_ROOT"
  echo SERVER_LOGS
  sed -n '1,120p' "$SMOKE/server.log" || true
  echo DAEMON_LOGS
  sed -n '1,160p' "$SMOKE/daemon.log" || true
  find "$ROOT_DIR" -maxdepth 5 -type f -name rclone.log -print -exec sed -n '1,160p' {} \; 2>/dev/null || true
  exit 1
fi

trap - EXIT
cleanup

echo "HOST_DAEMON_WEBDAV_WORKLOAD_SMOKE_OK node=$NODE_ID driver=$DRIVER volume=$VOLUME remote_root=$REMOTE_ROOT"
