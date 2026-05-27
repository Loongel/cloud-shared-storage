#!/bin/sh
set -eu

cat >&2 <<'EOF'
CSS_HD01_PRODUCTION_STACK_PLAN_REMOVED

This historical stack-plan smoke depended on removed CSS runtime stack
templates. Production CSS runtime now runs as host systemd services from the
deb package; Stack files are used only for application/scenario workloads.

Use the current validation path instead:

  scripts/css-scenario-test-deploy.sh
  scripts/css-scenario-test-batch.sh
EOF

exit 2
