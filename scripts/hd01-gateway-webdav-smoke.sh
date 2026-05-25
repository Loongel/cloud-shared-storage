#!/bin/sh
set -eu
GO_BIN=${GO_BIN:-/tmp/cs-storage-go/go/bin/go}
WORKDIR=
SMOKE=${SMOKE:-/tmp/cs-gateway-webdav-smoke}
STREAM_BYTES=${STREAM_BYTES:-67108864}
RSS_DELTA_LIMIT_KB=${RSS_DELTA_LIMIT_KB:-51200}
SERVER_PORT=${SERVER_PORT:-18111}
SECRET=${SECRET:-cs-webdav-secret}
NODE=${NODE:-node-a}
REMOTE_ROOT=${REMOTE_ROOT:-cs-storage-smoke-$(date +%s)-$$}
FILE_NAME=${FILE_NAME:-stream.bin}
: "${CS_WEBDAV_URL:?CS_WEBDAV_URL is required}"
: "${CS_WEBDAV_USER:?CS_WEBDAV_USER is required}"
: "${CS_WEBDAV_PASSWORD:?CS_WEBDAV_PASSWORD is required}"
cd "$WORKDIR"
rm -rf "$SMOKE"
mkdir -p "$SMOKE/bin"
"$GO_BIN" build -buildvcs=false -o "$SMOKE/bin/cs-storage-server" ./cmd/cs-storage-server
BASE_URL=${CS_WEBDAV_URL%/}
BASE_HOST=$(python3 -c 'import sys,urllib.parse; print(urllib.parse.urlparse(sys.argv[1]).hostname or "")' "$BASE_URL")
if test -z "$BASE_HOST"; then
  echo INVALID_WEBDAV_URL
  exit 1
fi
NETRC="$SMOKE/curl.netrc"
umask 077
cat > "$NETRC" <<EOF
machine $BASE_HOST
login $CS_WEBDAV_USER
password $CS_WEBDAV_PASSWORD
EOF
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
sampler_pid=
cleanup() {
  kill "${server_pid:-}" "${sampler_pid:-}" 2>/dev/null || true
  wait "${server_pid:-}" "${sampler_pid:-}" 2>/dev/null || true
  cleanup_remote
  rm -f "$NETRC"
}
trap cleanup EXIT
cleanup_remote
mkcol "$REMOTE_ROOT"
mkcol "$REMOTE_ROOT/nodes"
mkcol "$REMOTE_ROOT/nodes/$NODE"
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
rss_kb() {
  awk '/VmRSS:/ {print $2}' "/proc/$server_pid/status" 2>/dev/null || printf '0\n'
}
baseline=$(rss_kb)
ts=$(date +%s)
sig=$(python3 -c 'import hmac,hashlib,sys; secret,node,ts=sys.argv[1:4]; print(hmac.new(secret.encode(), f"{node}\n{ts}".encode(), hashlib.sha256).hexdigest())' "$SECRET" "$NODE" "$ts")
token=$(curl -fsS -X POST "http://127.0.0.1:$SERVER_PORT/auth" -H 'Content-Type: application/json' -d "{\"node_id\":\"$NODE\",\"timestamp\":$ts,\"signature\":\"$sig\"}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
(
  while kill -0 "$server_pid" 2>/dev/null; do
    rss_kb >> "$SMOKE/rss.log"
    sleep 0.1
  done
) &
sampler_pid=$!
truncate -s "$STREAM_BYTES" "$SMOKE/payload.bin"
curl -fsS -H "Authorization: Bearer $token" --upload-file "$SMOKE/payload.bin" "http://127.0.0.1:$SERVER_PORT/$FILE_NAME" >/dev/null
kill "$sampler_pid" 2>/dev/null || true
wait "$sampler_pid" 2>/dev/null || true
sampler_pid=
max_rss=$(sort -nr "$SMOKE/rss.log" | sed -n '1p')
propfind="$SMOKE/propfind.xml"
curl -fsS --netrc-file "$NETRC" -X PROPFIND -H 'Depth: 0' "$BASE_URL/$REMOTE_ROOT/nodes/$NODE/$FILE_NAME" > "$propfind"
remote_size=$(python3 -c 'import re,sys; data=open(sys.argv[1], encoding="utf-8", errors="ignore").read(); m=re.search(r"<[^>]*getcontentlength[^>]*>([0-9]+)</", data); print(m.group(1) if m else "")' "$propfind")
if test "$remote_size" != "$STREAM_BYTES"; then
  echo "WEBDAV_GATEWAY_SIZE_MISMATCH got=$remote_size want=$STREAM_BYTES"
  exit 1
fi
delta=$((max_rss - baseline))
if test "$delta" -gt "$RSS_DELTA_LIMIT_KB"; then
  echo "WEBDAV_GATEWAY_RSS_TOO_HIGH baseline_kb=$baseline max_kb=$max_rss delta_kb=$delta limit_kb=$RSS_DELTA_LIMIT_KB"
  exit 1
fi
trap - EXIT
cleanup
echo "WEBDAV_GATEWAY_STREAM_SMOKE_OK bytes=$STREAM_BYTES baseline_kb=$baseline max_kb=$max_rss delta_kb=$delta"
