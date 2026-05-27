#!/bin/sh
set -eu

cat >&2 <<'EOF'
CSS_SWARM_CLIENT_ROLLOUT_REMOVED

This script is intentionally disabled.

Do not use Docker Swarm services or helper containers to install, upgrade, or
restart CS-Storage host services across nodes. That path can disturb the same
Swarm control plane and overlay network that the scenario tests are supposed to
validate.

Supported upgrade paths are:

1. Per-node local installer:

   curl -fsSL https://raw.githubusercontent.com/Loongel/cloud-shared-storage/main/scripts/css-install-client.sh \
     | sudo sh -s -- --server-url <server-url> --node-secret '<secret>' --gocryptfs-password '<password>'

2. Deb-managed local auto-upgrade:

   sudo systemctl enable --now cs-storage-auto-upgrade.timer
   sudo systemctl start cs-storage-auto-upgrade.service

Both paths run locally on each host through systemd/apt and preserve
/etc/cs-storage configuration and secrets.
EOF

exit 2
