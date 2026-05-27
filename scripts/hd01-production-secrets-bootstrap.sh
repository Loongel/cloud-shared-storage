#!/bin/sh
set -eu

if test "${CSS_ALLOW_HISTORICAL_SWARM_HOST_HELPER:-}" != "yes"; then
  cat >&2 <<'EOF'
CSS_HISTORICAL_SWARM_HOST_HELPER_DISABLED

This script writes host /etc/cs-storage files through a Swarm global helper.
That cross-node host-mutation path is disabled by default. Use the local
role-specific installers on each node instead: css-install-server.sh,
css-install-client.sh, or css-install-all.sh.
EOF
  exit 2
fi

STACK=${STACK:-cs-storage-production-secrets-bootstrap}
IMAGE=${IMAGE:-alpine:3.20}
SMOKE=${SMOKE:-/tmp/cs-storage-production-secrets-bootstrap}
ENV_DIR=${ENV_DIR:-/etc/cs-storage}
SECRET_DIR=${SECRET_DIR:-secrets}
CONTAINER_SECRET_DIR=${CONTAINER_SECRET_DIR:-/run/cs-storage-secrets}
SERVER_ENV=${SERVER_ENV:-server.env}
DAEMON_ENV=${DAEMON_ENV:-daemon.env}
PLUGIN_ENV=${PLUGIN_ENV:-plugin.env}
APPLY=${APPLY:-0}
ACK_WRITE_PRODUCTION_SECRETS=${ACK_WRITE_PRODUCTION_SECRETS:-}
NODES_MIN=${NODES_MIN:-}
DOCKER_TIMEOUT=${DOCKER_TIMEOUT:-20s}
SERVICE_WAIT_ATTEMPTS=${SERVICE_WAIT_ATTEMPTS:-60}
CLEANUP_WAIT_ATTEMPTS=${CLEANUP_WAIT_ATTEMPTS:-12}

CS_PLUGIN_SOCKET=${CS_PLUGIN_SOCKET:-/run/docker/plugins/css.sock}
CS_DAEMON_SOCKET=${CS_DAEMON_SOCKET:-/run/cs-storage.sock}
CS_DOCKER_SOCKET=${CS_DOCKER_SOCKET:-/var/run/docker.sock}
CS_PLUGIN_TIMEOUT=${CS_PLUGIN_TIMEOUT:-120s}

docker_t() {
  timeout "$DOCKER_TIMEOUT" docker "$@"
}

need_env() {
  key=$1
  eval "value=\${$key:-}"
  if test -z "$value"; then
    echo "PRODUCTION_SECRETS_BOOTSTRAP_MISSING_ENV key=$key"
    exit 1
  fi
}

cleanup() {
  docker_t stack rm "$STACK" >/dev/null 2>&1 || true
  for _ in $(seq 1 "$CLEANUP_WAIT_ATTEMPTS"); do
    if ! docker_t stack ps "$STACK" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  for secret in ${SERVER_SECRET:-} ${DAEMON_SECRET:-} ${PLUGIN_SECRET:-} ${NODE_SECRET:-} ${BACKEND_AUTH_HEADER_SECRET:-} ${BACKEND_USER_SECRET:-} ${BACKEND_PASSWORD_SECRET:-} ${GOCRYPTFS_SECRET:-}; do
    if test -n "$secret"; then
      docker_t secret rm "$secret" >/dev/null 2>&1 || true
    fi
  done
  rm -rf "$SMOKE"
}

state=$(docker_t info --format '{{.Swarm.LocalNodeState}}')
if test "$state" != "active"; then
  echo "PRODUCTION_SECRETS_BOOTSTRAP_SWARM_NOT_ACTIVE state=$state"
  exit 1
fi

active_nodes=$(docker_t node ls --format '{{.Status}}' | awk '$1 == "Ready" {n++} END {print n+0}')
if test -z "$NODES_MIN"; then
  NODES_MIN=$active_nodes
fi
if test "$active_nodes" -lt "$NODES_MIN"; then
  echo "PRODUCTION_SECRETS_BOOTSTRAP_NOT_ENOUGH_NODES ready=$active_nodes min=$NODES_MIN"
  exit 1
fi

need_env CS_NODE_SECRET_KEY
need_env CS_BACKEND_URL
need_env CS_SERVER_URL
need_env CS_GOCRYPTFS_PASSWORD

AUTH_MODE=header
if test -z "${CS_BACKEND_AUTH_HEADER:-}"; then
  AUTH_MODE=basic
  need_env CS_BACKEND_USER
  need_env CS_BACKEND_PASSWORD
fi

if test "$APPLY" != "1"; then
  echo "PRODUCTION_SECRETS_BOOTSTRAP_DRY_RUN nodes=$active_nodes min=$NODES_MIN env_dir=$ENV_DIR secret_dir=$ENV_DIR/$SECRET_DIR"
  echo "PRODUCTION_SECRETS_BOOTSTRAP_DRY_RUN_KEYS server=$SERVER_ENV daemon=$DAEMON_ENV plugin=$PLUGIN_ENV"
  exit 0
fi
if test "$ACK_WRITE_PRODUCTION_SECRETS" != "yes"; then
  echo "PRODUCTION_SECRETS_BOOTSTRAP_REFUSE_APPLY missing_ack=ACK_WRITE_PRODUCTION_SECRETS=yes"
  exit 1
fi

rm -rf "$SMOKE"
mkdir -p "$SMOKE"
chmod 700 "$SMOKE"
trap cleanup EXIT

suffix=$(date +%s)-$$
secret_base=$(printf '%s' "$STACK" | tr -c 'a-zA-Z0-9_.-' '-' | cut -c1-30)-$suffix
SERVER_SECRET=${secret_base}-srv
DAEMON_SECRET=${secret_base}-dmn
PLUGIN_SECRET=${secret_base}-plg
NODE_SECRET=${secret_base}-node
BACKEND_AUTH_HEADER_SECRET=${secret_base}-bah
BACKEND_USER_SECRET=${secret_base}-bu
BACKEND_PASSWORD_SECRET=${secret_base}-bp
GOCRYPTFS_SECRET=${secret_base}-gcf

printf '%s' "$CS_NODE_SECRET_KEY" | docker_t secret create "$NODE_SECRET" - >/dev/null
printf '%s' "${CS_BACKEND_AUTH_HEADER:-__unused__}" | docker_t secret create "$BACKEND_AUTH_HEADER_SECRET" - >/dev/null
printf '%s' "${CS_BACKEND_USER:-__unused__}" | docker_t secret create "$BACKEND_USER_SECRET" - >/dev/null
printf '%s' "${CS_BACKEND_PASSWORD:-__unused__}" | docker_t secret create "$BACKEND_PASSWORD_SECRET" - >/dev/null
printf '%s' "$CS_GOCRYPTFS_PASSWORD" | docker_t secret create "$GOCRYPTFS_SECRET" - >/dev/null

{
  printf 'CS_NODE_SECRET_KEY_FILE=%s/node_secret\n' "$CONTAINER_SECRET_DIR"
  printf 'CS_BACKEND_URL=%s\n' "$CS_BACKEND_URL"
  if test -n "${CS_BACKEND_AUTH_HEADER:-}"; then
    printf 'CS_BACKEND_AUTH_HEADER_FILE=%s/backend_auth_header\n' "$CONTAINER_SECRET_DIR"
  else
    printf 'CS_BACKEND_USER_FILE=%s/backend_user\n' "$CONTAINER_SECRET_DIR"
    printf 'CS_BACKEND_PASSWORD_FILE=%s/backend_password\n' "$CONTAINER_SECRET_DIR"
  fi
} | docker_t secret create "$SERVER_SECRET" - >/dev/null

{
  printf 'CS_DAEMON_SOCKET=%s\n' "$CS_DAEMON_SOCKET"
  printf 'CS_SERVER_URL=%s\n' "$CS_SERVER_URL"
  printf 'CS_NODE_SECRET_KEY_FILE=%s/node_secret\n' "$CONTAINER_SECRET_DIR"
  printf 'CS_GOCRYPTFS_PASSWORD_FILE=%s/gocryptfs_password\n' "$CONTAINER_SECRET_DIR"
} | docker_t secret create "$DAEMON_SECRET" - >/dev/null

{
  printf 'CS_PLUGIN_SOCKET=%s\n' "$CS_PLUGIN_SOCKET"
  printf 'CS_DAEMON_SOCKET=%s\n' "$CS_DAEMON_SOCKET"
  printf 'CS_DOCKER_SOCKET=%s\n' "$CS_DOCKER_SOCKET"
  printf 'CS_PLUGIN_TIMEOUT=%s\n' "$CS_PLUGIN_TIMEOUT"
} | docker_t secret create "$PLUGIN_SECRET" - >/dev/null

cat > "$SMOKE/stack.yml" <<STACK_EOF
version: "3.8"
services:
  bootstrap:
    image: $IMAGE
    command:
      - /bin/sh
      - -c
      - |
        set -eu
        umask 077
        node=\$\$(cat /host/etc/hostname 2>/dev/null || hostname)
        auth_mode=$AUTH_MODE
        target=/host$ENV_DIR
        secret_target="\$\$target/$SECRET_DIR"
        mkdir -p "\$\$target" "\$\$secret_target"
        cp /run/secrets/node_secret "\$\$secret_target/node_secret.tmp"
        chmod 600 "\$\$secret_target/node_secret.tmp"
        mv "\$\$secret_target/node_secret.tmp" "\$\$secret_target/node_secret"
        if test "\$\$auth_mode" = "header"; then
          cp /run/secrets/backend_auth_header "\$\$secret_target/backend_auth_header.tmp"
          chmod 600 "\$\$secret_target/backend_auth_header.tmp"
          mv "\$\$secret_target/backend_auth_header.tmp" "\$\$secret_target/backend_auth_header"
          rm -f "\$\$secret_target/backend_user" "\$\$secret_target/backend_password"
        else
          cp /run/secrets/backend_user "\$\$secret_target/backend_user.tmp"
          chmod 600 "\$\$secret_target/backend_user.tmp"
          mv "\$\$secret_target/backend_user.tmp" "\$\$secret_target/backend_user"
          cp /run/secrets/backend_password "\$\$secret_target/backend_password.tmp"
          chmod 600 "\$\$secret_target/backend_password.tmp"
          mv "\$\$secret_target/backend_password.tmp" "\$\$secret_target/backend_password"
          rm -f "\$\$secret_target/backend_auth_header"
        fi
        cp /run/secrets/gocryptfs_password "\$\$secret_target/gocryptfs_password.tmp"
        chmod 600 "\$\$secret_target/gocryptfs_password.tmp"
        mv "\$\$secret_target/gocryptfs_password.tmp" "\$\$secret_target/gocryptfs_password"
        cat /run/secrets/server_env > "\$\$target/$SERVER_ENV.tmp"
        chmod 600 "\$\$target/$SERVER_ENV.tmp"
        mv "\$\$target/$SERVER_ENV.tmp" "\$\$target/$SERVER_ENV"
        {
          cat /run/secrets/daemon_env
          printf 'CS_NODE_ID=%s\\n' "\$\$node"
        } > /tmp/$DAEMON_ENV
        cp /tmp/$DAEMON_ENV "\$\$target/$DAEMON_ENV.tmp"
        chmod 600 "\$\$target/$DAEMON_ENV.tmp"
        mv "\$\$target/$DAEMON_ENV.tmp" "\$\$target/$DAEMON_ENV"
        cp /run/secrets/plugin_env "\$\$target/$PLUGIN_ENV.tmp"
        chmod 600 "\$\$target/$PLUGIN_ENV.tmp"
        mv "\$\$target/$PLUGIN_ENV.tmp" "\$\$target/$PLUGIN_ENV"
        echo "PRODUCTION_SECRETS_BOOTSTRAP_NODE node=\$\$node ok"
    volumes:
      - type: bind
        source: /
        target: /host
    secrets:
      - server_env
      - daemon_env
      - plugin_env
      - node_secret
      - backend_auth_header
      - backend_user
      - backend_password
      - gocryptfs_password
    deploy:
      mode: global
      restart_policy:
        condition: none
secrets:
  server_env:
    external: true
    name: $SERVER_SECRET
  daemon_env:
    external: true
    name: $DAEMON_SECRET
  plugin_env:
    external: true
    name: $PLUGIN_SECRET
  node_secret:
    external: true
    name: $NODE_SECRET
  backend_auth_header:
    external: true
    name: $BACKEND_AUTH_HEADER_SECRET
  backend_user:
    external: true
    name: $BACKEND_USER_SECRET
  backend_password:
    external: true
    name: $BACKEND_PASSWORD_SECRET
  gocryptfs_password:
    external: true
    name: $GOCRYPTFS_SECRET
STACK_EOF

docker_t stack deploy -c "$SMOKE/stack.yml" "$STACK" >/dev/null
service="${STACK}_bootstrap"
completed=0
failed=0
for _ in $(seq 1 "$SERVICE_WAIT_ATTEMPTS"); do
  docker_t service ps "$service" --no-trunc --format '{{.Node}}|{{.CurrentState}}|{{.Error}}' > "$SMOKE/service-ps.txt" 2>/dev/null || true
  completed=$(awk -F'|' '$2 ~ /^Complete/ {print $1}' "$SMOKE/service-ps.txt" | sort -u | wc -l | tr -d ' ')
  failed=$(awk -F'|' '$2 ~ /^Failed|^Rejected/ || $3 != "" {n++} END {print n+0}' "$SMOKE/service-ps.txt")
  if test "$completed" -ge "$NODES_MIN"; then
    break
  fi
  sleep 1
done

docker_t service logs "$service" > "$SMOKE/logs.txt" 2>/dev/null || true
cat "$SMOKE/logs.txt"

if test "$completed" -lt "$NODES_MIN" || test "$failed" -gt 0; then
  docker_t service ps "$service" --no-trunc || true
  echo "PRODUCTION_SECRETS_BOOTSTRAP_INCOMPLETE completed=$completed failed=$failed min=$NODES_MIN ready=$active_nodes"
  exit 1
fi

trap - EXIT
cleanup
echo "PRODUCTION_SECRETS_BOOTSTRAP_OK nodes=$completed ready=$active_nodes env_dir=$ENV_DIR secret_dir=$ENV_DIR/$SECRET_DIR"
