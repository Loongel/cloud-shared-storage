#!/bin/sh
set -eu

cat >&2 <<'EOF'
CSS_HD01_PRODUCTION_INSTALL_REMOVED

This historical all-in-one hd01 installer has been removed from the active
delivery path. It previously represented a Swarm/container rollout model, while
the formal CSS deployment is local deb + systemd on each node.

Use the role-specific one-command installers instead:

  css-install-server.sh
  css-install-client.sh
  css-install-all.sh

Package upgrades are handled locally by cs-storage-auto-upgrade.timer. Docker
Stack/Swarm is reserved for post-install scenario validation only.
EOF

exit 2
