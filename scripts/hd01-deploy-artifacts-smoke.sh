#!/bin/sh
set -eu
GO_IMAGE=${GO_IMAGE:-golang:1.22-bookworm}
SMOKE=${SMOKE:-/tmp/cs-storage-deploy-artifacts}
rm -rf "$SMOKE"
mkdir -p "$SMOKE"
sh -n deploy/install/install.sh scripts/hd01-production-install.sh
for unit in deploy/systemd/cs-storage-server.service deploy/systemd/cs-storage-daemon.service deploy/systemd/cs-storage-plugin.service; do
  grep -q '^\[Unit\]' "$unit"
  grep -q '^\[Service\]' "$unit"
  grep -q '^ExecStart=' "$unit"
done
docker run --rm --network host -v "$PWD:/src:ro" -v "$SMOKE:/out" -w /src "$GO_IMAGE" sh -lc "/usr/local/go/bin/go build -buildvcs=false -o /out/cs-storage-admin ./cmd/cs-storage-admin"
"$SMOKE/cs-storage-admin" render-compose -in deploy/stack/example-app.yml -out "$SMOKE/example-app.rendered.yml"
grep -q 'driver_opts:' "$SMOKE/example-app.rendered.yml"
grep -q 'cs.mode: shared' "$SMOKE/example-app.rendered.yml"
grep -q 'cs.write: single' "$SMOKE/example-app.rendered.yml"
CS_STORAGE_IMAGE=busybox:1.36 docker compose -f deploy/stack/cs-storage-plugin-global.yml config >/dev/null
CS_STORAGE_IMAGE=busybox:1.36 CS_SERVER_URL=http://127.0.0.1:18080 CS_NODE_SECRET_KEY=dummy CS_GOCRYPTFS_PASSWORD=dummy docker compose -f deploy/stack/cs-storage-daemon-global.yml config > "$SMOKE/daemon-stack.yml"
grep -q CS_LITEFS_CONSUL_KEY "$SMOKE/daemon-stack.yml"
grep -q CS_LITEFS_CONSUL_TOKEN "$SMOKE/daemon-stack.yml"
grep -q CS_RCLONE_SYNC_SOURCE "$SMOKE/daemon-stack.yml"
grep -q CS_KOPIA_CONFIG_PATH "$SMOKE/daemon-stack.yml"
grep -q CS_ROUTER_BINARY "$SMOKE/daemon-stack.yml"
CS_STORAGE_IMAGE=busybox:1.36 CS_NODE_SECRET_KEY=dummy CS_BACKEND_URL=http://127.0.0.1:9 CS_BACKEND_USER=dummy-user CS_BACKEND_PASSWORD=dummy-pass docker compose -f deploy/stack/cs-storage-server.yml config > "$SMOKE/server-stack.yml"
grep -q CS_BACKEND_USER "$SMOKE/server-stack.yml"
grep -q CS_BACKEND_PASSWORD "$SMOKE/server-stack.yml"
grep -q CS_BACKEND_USER_FILE "$SMOKE/server-stack.yml"
grep -q CS_BACKEND_PASSWORD_FILE "$SMOKE/server-stack.yml"
grep -q CS_NODE_SECRET_KEY_FILE "$SMOKE/server-stack.yml"
grep -q CS_GOCRYPTFS_PASSWORD_FILE "$SMOKE/daemon-stack.yml"
grep -q CS_COORDINATOR_TOKEN "$SMOKE/server-stack.yml"
docker compose -f "$SMOKE/example-app.rendered.yml" config >/dev/null
if grep -F -e '$SMOKE/server.env' -e '$SMOKE/daemon.env' -e '$SMOKE/plugin.env' scripts/hd01-production-secrets-bootstrap.sh; then
  echo "DEPLOY_ARTIFACTS_SECRET_TEMPFILE_REF_FOUND"
  exit 1
fi
grep -F -q 'secret create "$SERVER_SECRET" -' scripts/hd01-production-secrets-bootstrap.sh
grep -F -q 'secret create "$DAEMON_SECRET" -' scripts/hd01-production-secrets-bootstrap.sh
grep -F -q 'secret create "$PLUGIN_SECRET" -' scripts/hd01-production-secrets-bootstrap.sh
grep -F -q 'CS_NODE_SECRET_KEY_FILE=' scripts/hd01-production-secrets-bootstrap.sh
grep -F -q 'CS_GOCRYPTFS_PASSWORD_FILE=' scripts/hd01-production-secrets-bootstrap.sh

mkdir -p "$SMOKE/install-src/bin" "$SMOKE/install-src/deploy"
cp -R deploy/systemd deploy/env "$SMOKE/install-src/deploy/"
for bin in cs-storage-server cs-storage-daemon cs-storage-plugin cs-storage-admin cs-storage-router; do
  printf '#!/bin/sh\n' > "$SMOKE/install-src/bin/$bin"
  chmod 755 "$SMOKE/install-src/bin/$bin"
done
PREFIX="$SMOKE/install-prefix" \
SYSTEMD_DIR="$SMOKE/install-systemd" \
ENV_DIR="$SMOKE/install-env" \
STATE_DIR="$SMOKE/install-state" \
LOG_DIR="$SMOKE/install-log" \
CREATE_SERVICE_USER=0 \
RELOAD_SYSTEMD=0 \
SRC_DIR="$SMOKE/install-src" \
./deploy/install/install.sh > "$SMOKE/install.out"
test -x "$SMOKE/install-prefix/cs-storage-server"
test -f "$SMOKE/install-systemd/cs-storage-server.service"
test -f "$SMOKE/install-env/server.env"
test -d "$SMOKE/install-state"
test -d "$SMOKE/install-log"
grep -q 'useradd --system' deploy/install/install.sh
grep -q 'STATE_DIR' deploy/install/install.sh
echo "STACK_ENV_PARITY_OK"
echo "SERVER_STACK_FILE_SECRET_RENDER_OK"
echo "INSTALL_ARTIFACTS_STAGED_OK"
echo "PRODUCTION_SECRETS_BOOTSTRAP_STDIN_OK"
echo "DEPLOY_ARTIFACTS_SMOKE_OK"
