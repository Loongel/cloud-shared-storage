#!/bin/sh
set -eu

SMOKE=${SMOKE:-/tmp/cs-storage-production-stack-plan}
ENV_DIR=${ENV_DIR:-/etc/cs-storage}
IMAGE=${IMAGE:-cs-storage:hd01-smoke}
DUMMY=${DUMMY:-0}
DOCKER_TIMEOUT=${DOCKER_TIMEOUT:-20s}

SERVER_ENV=${SERVER_ENV:-$ENV_DIR/server.env}
DAEMON_ENV=${DAEMON_ENV:-$ENV_DIR/daemon.env}
PLUGIN_ENV=${PLUGIN_ENV:-$ENV_DIR/plugin.env}

missing=""
add_missing() {
  if test -z "$missing"; then
    missing="$1"
  else
    missing="$missing,$1"
  fi
}

docker_t() {
  timeout "$DOCKER_TIMEOUT" docker "$@"
}

load_env_file() {
  file=$1
  label=$2
  if ! test -s "$file"; then
    add_missing "$label=$file"
    return
  fi
  # shellcheck disable=SC1090
  set -a
  . "$file"
  set +a
}

if test "$DUMMY" = "1"; then
  export CS_STORAGE_IMAGE="$IMAGE"
  export CS_NODE_SECRET_KEY_FILE=/run/cs-storage-secrets/node_secret
  export CS_BACKEND_URL=http://127.0.0.1:9
  export CS_BACKEND_USER_FILE=/run/cs-storage-secrets/backend_user
  export CS_BACKEND_PASSWORD_FILE=/run/cs-storage-secrets/backend_password
  export CS_SERVER_URL=http://127.0.0.1:8080
  export CS_GOCRYPTFS_PASSWORD_FILE=/run/cs-storage-secrets/gocryptfs_password
else
  load_env_file "$SERVER_ENV" server_env
  load_env_file "$DAEMON_ENV" daemon_env
  load_env_file "$PLUGIN_ENV" plugin_env
  if test -n "$missing"; then
    echo "PRODUCTION_STACK_PLAN_MISSING_ENV missing=$missing"
    exit 1
  fi
  for key in CS_BACKEND_URL CS_SERVER_URL; do
    eval "value=\${$key:-}"
    if test -z "$value"; then
      add_missing "key=$key"
    fi
  done
  for key in CS_NODE_SECRET_KEY CS_GOCRYPTFS_PASSWORD; do
    eval "value=\${$key:-}"
    eval "file_value=\${${key}_FILE:-}"
    if test -z "$value$file_value"; then
      add_missing "key=$key"
    fi
  done
  if test -z "${CS_BACKEND_AUTH_HEADER:-}${CS_BACKEND_AUTH_HEADER_FILE:-}"; then
    test -n "${CS_BACKEND_USER:-}${CS_BACKEND_USER_FILE:-}" || add_missing key=CS_BACKEND_USER
    test -n "${CS_BACKEND_PASSWORD:-}${CS_BACKEND_PASSWORD_FILE:-}" || add_missing key=CS_BACKEND_PASSWORD
  fi
  if test -n "$missing"; then
    echo "PRODUCTION_STACK_PLAN_MISSING_ENV missing=$missing"
    exit 1
  fi
  export CS_STORAGE_IMAGE="$IMAGE"
  export CS_NODE_SECRET_KEY=
  export CS_NODE_SECRET_KEY_FILE=/run/cs-storage-secrets/node_secret
  export CS_BACKEND_URL=http://127.0.0.1:9
  export CS_BACKEND_AUTH_HEADER=
  export CS_BACKEND_AUTH_HEADER_FILE=
  export CS_BACKEND_USER=
  export CS_BACKEND_USER_FILE=/run/cs-storage-secrets/backend_user
  export CS_BACKEND_PASSWORD=
  export CS_BACKEND_PASSWORD_FILE=/run/cs-storage-secrets/backend_password
  export CS_SERVER_URL=http://127.0.0.1:8080
  export CS_GOCRYPTFS_PASSWORD=
  export CS_GOCRYPTFS_PASSWORD_FILE=/run/cs-storage-secrets/gocryptfs_password
fi

for key in CS_BACKEND_URL CS_SERVER_URL; do
  eval "value=\${$key:-}"
  if test -z "$value"; then
    add_missing "key=$key"
  fi
done
for key in CS_NODE_SECRET_KEY CS_GOCRYPTFS_PASSWORD; do
  eval "value=\${$key:-}"
  eval "file_value=\${${key}_FILE:-}"
  if test -z "$value$file_value"; then
    add_missing "key=$key"
  fi
done
if test -z "${CS_BACKEND_AUTH_HEADER:-}${CS_BACKEND_AUTH_HEADER_FILE:-}"; then
  test -n "${CS_BACKEND_USER:-}${CS_BACKEND_USER_FILE:-}" || add_missing key=CS_BACKEND_USER
  test -n "${CS_BACKEND_PASSWORD:-}${CS_BACKEND_PASSWORD_FILE:-}" || add_missing key=CS_BACKEND_PASSWORD
fi
if test -n "$missing"; then
  echo "PRODUCTION_STACK_PLAN_MISSING_ENV missing=$missing"
  exit 1
fi

state=$(docker_t info --format '{{.Swarm.LocalNodeState}}')
if test "$state" != active; then
  echo "PRODUCTION_STACK_PLAN_SWARM_NOT_ACTIVE state=$state"
  exit 1
fi
nodes=$(docker_t node ls --format '{{.Status}}' | awk '$1 == "Ready" {n++} END {print n+0}')

rm -rf "$SMOKE"
mkdir -p "$SMOKE"

CS_STORAGE_IMAGE="$IMAGE" docker compose -f deploy/stack/cs-storage-server.yml config > "$SMOKE/server.compose.yml"
CS_STORAGE_IMAGE="$IMAGE" docker compose -f deploy/stack/cs-storage-daemon-global.yml config > "$SMOKE/daemon.compose.yml"
CS_STORAGE_IMAGE="$IMAGE" docker compose -f deploy/stack/cs-storage-plugin-global.yml config > "$SMOKE/plugin.compose.yml"

CS_STORAGE_IMAGE="$IMAGE" docker stack config -c deploy/stack/cs-storage-server.yml > "$SMOKE/server.stack.yml"
CS_STORAGE_IMAGE="$IMAGE" docker stack config -c deploy/stack/cs-storage-daemon-global.yml > "$SMOKE/daemon.stack.yml"
CS_STORAGE_IMAGE="$IMAGE" docker stack config -c deploy/stack/cs-storage-plugin-global.yml > "$SMOKE/plugin.stack.yml"

grep -q "cs-storage-server" "$SMOKE/server.compose.yml"
grep -q "cs-storage-daemon" "$SMOKE/daemon.compose.yml"
grep -q "cs-storage-plugin" "$SMOKE/plugin.compose.yml"
grep -q "mode: global" "$SMOKE/daemon.stack.yml"
grep -q "mode: global" "$SMOKE/plugin.stack.yml"
grep -q "CS_NODE_ID.*{{.Node.Hostname}}" "$SMOKE/daemon.compose.yml"
grep -q "CS_BACKEND_USER_FILE" "$SMOKE/server.compose.yml"
grep -q "CS_BACKEND_PASSWORD_FILE" "$SMOKE/server.compose.yml"
grep -q "CS_NODE_SECRET_KEY_FILE" "$SMOKE/server.compose.yml"
grep -q "CS_GOCRYPTFS_PASSWORD_FILE" "$SMOKE/daemon.compose.yml"

if grep -R -q "plan-redacted-password\|plan-redacted-node-secret\|plan-redacted-gocryptfs" "$SMOKE"; then
  echo "PRODUCTION_STACK_PLAN_REDACTION_LEAK"
  exit 1
fi
if ! grep -R -q "/run/cs-storage-secrets" "$SMOKE"; then
  echo "PRODUCTION_STACK_PLAN_FILE_SECRET_MISSING"
  exit 1
fi

echo "PRODUCTION_STACK_PLAN_REDACTED_OK"
echo "PRODUCTION_STACK_PLAN_FILE_SECRET_OK"
echo "PRODUCTION_STACK_PLAN_OK nodes=$nodes image=$IMAGE dummy=$DUMMY out=$SMOKE"
