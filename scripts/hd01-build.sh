#!/bin/sh
set -eu
GO_BIN=${GO_BIN:-/tmp/cs-storage-go/go/bin/go}
GOFMT_BIN=${GOFMT_BIN:-$(dirname "$GO_BIN")/gofmt}
"$GOFMT_BIN" -w cmd internal
"$GO_BIN" test ./...
"$GO_BIN" build -buildvcs=false ./cmd/cs-storage-server ./cmd/cs-storage-daemon ./cmd/cs-storage-plugin ./cmd/cs-storage-admin ./cmd/cs-storage-router
