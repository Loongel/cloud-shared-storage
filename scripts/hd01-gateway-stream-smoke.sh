#!/bin/sh
set -eu
GO_BIN=${GO_BIN:-/tmp/cs-storage-go/go/bin/go}
WORKDIR=
SMOKE=${SMOKE:-/tmp/cs-gateway-stream-smoke}
STREAM_BYTES=${STREAM_BYTES:-268435456}
RSS_DELTA_LIMIT_KB=${RSS_DELTA_LIMIT_KB:-51200}
SERVER_PORT=${SERVER_PORT:-18101}
BACKEND_PORT=${BACKEND_PORT:-18102}
SECRET=${SECRET:-cs-stream-secret}
NODE=${NODE:-node-a}
cd "$WORKDIR"
rm -rf "$SMOKE"
mkdir -p "$SMOKE/bin"
"$GO_BIN" build -buildvcs=false -o "$SMOKE/bin/cs-storage-server" ./cmd/cs-storage-server
cat > "$SMOKE/backend.py" <<'BACKEND_PY'
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
import sys

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_PUT(self):
        remaining = self.headers.get("Content-Length")
        remaining = int(remaining) if remaining else None
        total = 0
        while True:
            if remaining is None:
                chunk = self.rfile.read(1024 * 1024)
                if not chunk:
                    break
            else:
                if remaining <= 0:
                    break
                chunk = self.rfile.read(min(1024 * 1024, remaining))
                if not chunk:
                    break
                remaining -= len(chunk)
            total += len(chunk)
        with open(os.environ["BACKEND_COUNT_PATH"], "w", encoding="ascii") as f:
            f.write(str(total))
        self.send_response(201)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, fmt, *args):
        return

ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
BACKEND_PY
BACKEND_COUNT_PATH="$SMOKE/backend.count" python3 "$SMOKE/backend.py" "$BACKEND_PORT" > "$SMOKE/backend.log" 2>&1 &
backend_pid=$!
CS_SERVER_ADDR="127.0.0.1:$SERVER_PORT" \
CS_NODE_SECRET_KEY="$SECRET" \
CS_BACKEND_URL="http://127.0.0.1:$BACKEND_PORT/dav" \
CS_BACKEND_AUTH_HEADER="Basic backend-secret" \
CS_SANDBOX_PREFIX=/nodes \
"$SMOKE/bin/cs-storage-server" > "$SMOKE/server.log" 2>&1 &
server_pid=$!
cleanup() {
  kill "$server_pid" "$backend_pid" 2>/dev/null || true
  kill "${sampler_pid:-}" 2>/dev/null || true
  wait "$server_pid" "$backend_pid" "${sampler_pid:-}" 2>/dev/null || true
}
trap cleanup EXIT
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
    sleep 0.05
  done
) &
sampler_pid=$!
truncate -s "$STREAM_BYTES" "$SMOKE/payload.bin"
curl -fsS -H "Authorization: Bearer $token" --upload-file "$SMOKE/payload.bin" "http://127.0.0.1:$SERVER_PORT/stream.bin" >/dev/null
kill "$sampler_pid" 2>/dev/null || true
wait "$sampler_pid" 2>/dev/null || true
max_rss=$(sort -nr "$SMOKE/rss.log" | sed -n '1p')
count=$(cat "$SMOKE/backend.count")
if test "$count" != "$STREAM_BYTES"; then
  echo "GATEWAY_STREAM_COUNT_MISMATCH got=$count want=$STREAM_BYTES"
  exit 1
fi
delta=$((max_rss - baseline))
if test "$delta" -gt "$RSS_DELTA_LIMIT_KB"; then
  echo "GATEWAY_STREAM_RSS_TOO_HIGH baseline_kb=$baseline max_kb=$max_rss delta_kb=$delta limit_kb=$RSS_DELTA_LIMIT_KB"
  exit 1
fi
trap - EXIT
cleanup
echo "GATEWAY_STREAM_SMOKE_OK bytes=$STREAM_BYTES baseline_kb=$baseline max_kb=$max_rss delta_kb=$delta"
