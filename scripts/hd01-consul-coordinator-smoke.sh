#!/bin/sh
set -eu
GO_BIN=${GO_BIN:-/tmp/cs-storage-go/go/bin/go}
"$GO_BIN" test ./internal/gateway -run TestConsulKVAndSessionCompatibility -count=1
echo "CONSUL_COORDINATOR_SMOKE_OK"
