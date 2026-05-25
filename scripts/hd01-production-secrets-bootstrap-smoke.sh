#!/bin/sh
set -eu

RUN_ID=${RUN_ID:-$(date +%s)-$$}
IMAGE=${IMAGE:-alpine:3.20}
SMOKE=${SMOKE:-/tmp/cs-storage-production-secrets-bootstrap-smoke-$RUN_ID}
ENV_DIR=${ENV_DIR:-/tmp/cs-storage-production-secrets-bootstrap-smoke-env-$RUN_ID}
SECRET_DIR=${SECRET_DIR:-secrets}
CONTAINER_SECRET_DIR=${CONTAINER_SECRET_DIR:-/run/cs-storage-secrets}
STACK=${STACK:-cs-prod-sec-smoke-$RUN_ID}
BOOTSTRAP_STACK=${BOOTSTRAP_STACK:-$STACK-b}
PREFLIGHT_STACK=${PREFLIGHT_STACK:-$STACK-p}
CLEANUP_STACK=${CLEANUP_STACK:-$STACK-c}
NODES_MIN=${NODES_MIN:-}
DOCKER_TIMEOUT=${DOCKER_TIMEOUT:-20s}
CLEANUP_WAIT_ATTEMPTS=${CLEANUP_WAIT_ATTEMPTS:-60}

case "$ENV_DIR" in
  /tmp/cs-storage-production-secrets-bootstrap-smoke*) ;;
  *) echo "PRODUCTION_SECRETS_BOOTSTRAP_SMOKE_REFUSE_ENV_DIR path=$ENV_DIR"; exit 1 ;;
esac

docker_t() {
  timeout "$DOCKER_TIMEOUT" docker "$@"
}

cleanup_stack() {
  name=$1
  docker_t stack rm "$name" >/dev/null 2>&1 || true
  for _ in $(seq 1 "$CLEANUP_WAIT_ATTEMPTS"); do
    if ! docker_t stack ps "$name" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
}

cleanup_env_dir() {
  rm -rf "$SMOKE/cleanup"
  mkdir -p "$SMOKE/cleanup"
  cat > "$SMOKE/cleanup/stack.yml" <<STACK_EOF
version: "3.8"
services:
  cleanup:
    image: $IMAGE
    command:
      - /bin/sh
      - -c
      - |
        set -eu
        node=\$\$(cat /host/etc/hostname 2>/dev/null || hostname)
        rm -rf /host$ENV_DIR
        echo "PRODUCTION_SECRETS_BOOTSTRAP_SMOKE_CLEANUP_NODE node=\$\$node env_dir=$ENV_DIR"
    volumes:
      - type: bind
        source: /
        target: /host
    deploy:
      mode: global
      restart_policy:
        condition: none
STACK_EOF
  if ! docker_t stack deploy -c "$SMOKE/cleanup/stack.yml" "$CLEANUP_STACK" >/dev/null 2>"$SMOKE/cleanup/deploy.err"; then
    sed -n '1,20p' "$SMOKE/cleanup/deploy.err" || true
    return 0
  fi
  service="${CLEANUP_STACK}_cleanup"
  for _ in $(seq 1 120); do
    if ! docker_t service inspect "$service" >/dev/null 2>&1; then
      break
    fi
    completed=$(docker_t service ps "$service" --format '{{.Node}}|{{.CurrentState}}' 2>/dev/null | awk -F'|' '$2 ~ /^Complete/ {print $1}' | sort -u | wc -l | tr -d ' ')
    if test "${completed:-0}" -ge "$NODES_MIN"; then
      break
    fi
    ok=$(docker_t service logs --raw "$service" 2>/dev/null | awk '$1 == "PRODUCTION_SECRETS_BOOTSTRAP_SMOKE_CLEANUP_NODE" {n++} END {print n+0}' || true)
    if test "${ok:-0}" -ge "$NODES_MIN"; then
      break
    fi
    sleep 1
  done
  cleanup_stack "$CLEANUP_STACK"
}

cleanup() {
  cleanup_stack "$BOOTSTRAP_STACK"
  cleanup_stack "$PREFLIGHT_STACK"
  cleanup_env_dir
}

state=$(docker_t info --format '{{.Swarm.LocalNodeState}}')
if test "$state" != "active"; then
  echo "PRODUCTION_SECRETS_BOOTSTRAP_SMOKE_SWARM_NOT_ACTIVE state=$state"
  exit 1
fi
active_nodes=$(docker_t node ls --format '{{.Status}}' | awk '$1 == "Ready" {n++} END {print n+0}')
if test -z "$NODES_MIN"; then
  NODES_MIN=$active_nodes
fi
if test "$active_nodes" -lt "$NODES_MIN"; then
  echo "PRODUCTION_SECRETS_BOOTSTRAP_SMOKE_NOT_ENOUGH_NODES ready=$active_nodes min=$NODES_MIN"
  exit 1
fi

rm -rf "$SMOKE"
mkdir -p "$SMOKE"
trap cleanup EXIT
cleanup_env_dir

STACK="$BOOTSTRAP_STACK" IMAGE="$IMAGE" SMOKE="$SMOKE/bootstrap" ENV_DIR="$ENV_DIR" SECRET_DIR="$SECRET_DIR" CONTAINER_SECRET_DIR="$CONTAINER_SECRET_DIR" NODES_MIN="$NODES_MIN" CS_NODE_SECRET_KEY=smoke-node-secret CS_BACKEND_URL=http://127.0.0.1:9 CS_BACKEND_USER=smoke-backend-user CS_BACKEND_PASSWORD=smoke-backend-password CS_SERVER_URL=http://127.0.0.1:8080 CS_GOCRYPTFS_PASSWORD=smoke-gocryptfs-password APPLY=1 ACK_WRITE_PRODUCTION_SECRETS=yes ./scripts/hd01-production-secrets-bootstrap.sh | tee "$SMOKE/bootstrap.log"

grep -q "PRODUCTION_SECRETS_BOOTSTRAP_OK" "$SMOKE/bootstrap.log"

STACK="$PREFLIGHT_STACK" IMAGE="$IMAGE" SMOKE="$SMOKE/preflight" ENV_DIR="$ENV_DIR" SECRET_DIR="$SECRET_DIR" CONTAINER_SECRET_DIR="$CONTAINER_SECRET_DIR" NODES_MIN="$NODES_MIN" STRICT=1 ./scripts/hd01-production-secrets-preflight.sh | tee "$SMOKE/preflight.log"

grep -q "PRODUCTION_SECRETS_PREFLIGHT_OK" "$SMOKE/preflight.log"
grep -q "KEY_FILE_OK" "$SMOKE/preflight.log"

trap - EXIT
cleanup
rm -rf "$SMOKE"

echo "PRODUCTION_SECRETS_BOOTSTRAP_FILE_SECRET_SMOKE_OK nodes=$NODES_MIN ready=$active_nodes env_dir=$ENV_DIR secret_dir=$ENV_DIR/$SECRET_DIR"
