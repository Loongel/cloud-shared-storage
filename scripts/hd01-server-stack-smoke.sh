#!/bin/sh
set -eu

cat >&2 <<'EOF'
CSS_SERVER_STACK_SMOKE_REMOVED

The old server-as-container Stack smoke was removed from the active test path.
The CSS server is delivered as cs-storage-server.service from the deb package.

Use scripts/css-scenario-test-deploy.sh after installing the system services.
EOF

exit 2
