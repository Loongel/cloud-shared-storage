#!/bin/sh
set -eu

GO_BIN=${GO_BIN:-/tmp/cs-storage-go/go/bin/go}
WORKDIR=${WORKDIR:-/tmp/cs-storage-work-current}
SMOKE=${SMOKE:-/tmp/cs-gateway-authz-smoke}
SERVER_PORT=${SERVER_PORT:-18151}
BACKEND_PORT=${BACKEND_PORT:-18152}
SECRET=${SECRET:-cs-authz-secret}
NODE_A=${NODE_A:-node-a}
NODE_B=${NODE_B:-node-b}

cd "$WORKDIR"
rm -rf "$SMOKE"
mkdir -p "$SMOKE/bin"
"$GO_BIN" build -buildvcs=false -o "$SMOKE/bin/cs-storage-server" ./cmd/cs-storage-server
cat > "$SMOKE/backend.py" <<'BACKEND_PY'
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import sys

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_PUT(self):
        remaining = self.headers.get("Content-Length")
        remaining = int(remaining) if remaining else 0
        while remaining > 0:
            chunk = self.rfile.read(min(65536, remaining))
            if not chunk:
                break
            remaining -= len(chunk)
        rec = {
            "method": self.command,
            "path": self.path,
            "authorization": self.headers.get("Authorization", ""),
            "x_node": self.headers.get("X-CS-Node-ID", ""),
            "x_sandbox": self.headers.get("X-CS-Sandbox", ""),
        }
        with open(os.environ["BACKEND_LOG"], "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, sort_keys=True) + "\n")
        self.send_response(201)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, fmt, *args):
        return

ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
BACKEND_PY

BACKEND_LOG="$SMOKE/backend.jsonl" python3 "$SMOKE/backend.py" "$BACKEND_PORT" > "$SMOKE/backend.log" 2>&1 &
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
  wait "$server_pid" "$backend_pid" 2>/dev/null || true
  rm -rf "$SMOKE"
}
trap cleanup EXIT

for _ in $(seq 1 100); do
  if curl -fsS "http://127.0.0.1:$SERVER_PORT/healthz" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
curl -fsS "http://127.0.0.1:$SERVER_PORT/healthz" >/dev/null

token_for() {
  node=$1
  ts=$(date +%s)
  sig=$(python3 -c 'import hmac,hashlib,sys; secret,node,ts=sys.argv[1:4]; print(hmac.new(secret.encode(), f"{node}\n{ts}".encode(), hashlib.sha256).hexdigest())' "$SECRET" "$node" "$ts")
  curl -fsS -X POST "http://127.0.0.1:$SERVER_PORT/auth" -H 'Content-Type: application/json' -d "{\"node_id\":\"$node\",\"timestamp\":$ts,\"signature\":\"$sig\"}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])'
}

token_a=$(token_for "$NODE_A")
token_b=$(token_for "$NODE_B")

missing_code=$(curl -sS -o "$SMOKE/missing.out" -w '%{http_code}' --upload-file /dev/null "http://127.0.0.1:$SERVER_PORT/no-auth.bin" || true)
if test "$missing_code" != "403"; then
  echo "GATEWAY_AUTHZ_MISSING_JWT_UNEXPECTED http=$missing_code"
  exit 1
fi

echo node-a-payload | curl -fsS -H "Authorization: Bearer $token_a" --upload-file - "http://127.0.0.1:$SERVER_PORT/nodes/$NODE_B/evil.bin" >/dev/null
echo node-b-payload | curl -fsS -H "Authorization: Bearer $token_b" --upload-file - "http://127.0.0.1:$SERVER_PORT/safe.bin" >/dev/null

python3 - "$SMOKE/backend.jsonl" "$NODE_A" "$NODE_B" <<'PY'
import json
import sys
path, node_a, node_b = sys.argv[1:4]
with open(path, encoding="utf-8") as f:
    rows = [json.loads(line) for line in f]
if len(rows) != 2:
    raise SystemExit(f"expected 2 backend requests after missing-JWT rejection, got {len(rows)}")
want = [
    (f"/dav/nodes/{node_a}/nodes/{node_b}/evil.bin", "Basic backend-secret", node_a, f"/nodes/{node_a}"),
    (f"/dav/nodes/{node_b}/safe.bin", "Basic backend-secret", node_b, f"/nodes/{node_b}"),
]
for i, (row, expected) in enumerate(zip(rows, want), 1):
    exp_path, exp_auth, exp_node, exp_sandbox = expected
    got = (row.get("path"), row.get("authorization"), row.get("x_node"), row.get("x_sandbox"))
    if got != expected:
        raise SystemExit(f"backend request {i} mismatch: got={got!r} want={expected!r}")
    if "Bearer" in row.get("authorization", ""):
        raise SystemExit("node JWT leaked to backend Authorization header")
PY

trap - EXIT
cleanup
echo "GATEWAY_AUTHZ_SMOKE_OK node_a=$NODE_A node_b=$NODE_B missing_jwt=403 backend_requests=2"
