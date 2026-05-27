#!/bin/sh
set -eu

cat >&2 <<'EOF'
CSS_DAEMON_STACK_SMOKE_REMOVED

The old daemon-as-container Stack smoke was removed from the active test path.
The CSS daemon is delivered as cs-storage-daemon.service from the deb package.

Use scripts/css-scenario-test-deploy.sh after installing the system services.
EOF

exit 2
