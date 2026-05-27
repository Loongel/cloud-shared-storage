#!/bin/sh
set -eu

IMAGE=${IMAGE:-cs-storage:hd01-smoke}
GO_IMAGE=${GO_IMAGE:-golang:1.22-bookworm}
PROBE_IMAGE=${PROBE_IMAGE:-alpine:3.20}
LAUNCHER_IMAGE=${LAUNCHER_IMAGE:-docker:27-cli}
DOCKER_BUILD_ARGS=${DOCKER_BUILD_ARGS:---network host}
DOCKER_TIMEOUT=${DOCKER_TIMEOUT:-30s}

APPLY=${APPLY:-0}
ACK_PRODUCTION_INSTALL=${ACK_PRODUCTION_INSTALL:-}
ACK_INSTALL_HOST_DEPS=${ACK_INSTALL_HOST_DEPS:-}
ACK_WRITE_PRODUCTION_SECRETS=${ACK_WRITE_PRODUCTION_SECRETS:-}

NODES_MIN=${NODES_MIN:-}
SERVER_STACK=${SERVER_STACK:-cs-storage-server}
CLIENT_STACK=${CLIENT_STACK:-cs-storage-client-launcher}
SERVER_ENV=${SERVER_ENV:-/etc/cs-storage/server.env}
DAEMON_ENV=${DAEMON_ENV:-/etc/cs-storage/daemon.env}
PLUGIN_ENV=${PLUGIN_ENV:-/etc/cs-storage/plugin.env}
CS_SERVER_PORT=${CS_SERVER_PORT:-8080}
CS_SERVER_URL=${CS_SERVER_URL:-}

DAEMON_CONTAINER=${DAEMON_CONTAINER:-cs-storage-daemon}
PLUGIN_CONTAINER=${PLUGIN_CONTAINER:-cs-storage-plugin}
DAEMON_SOCKET=${DAEMON_SOCKET:-/run/cs-storage.sock}
PLUGIN_SOCKET=${PLUGIN_SOCKET:-/run/docker/plugins/css.sock}
ROOT_DIR=${ROOT_DIR:-/mnt/cs_storage/vols}
AUDIT_LOG=${AUDIT_LOG:-/mnt/cs_storage/vols/.state/audit.jsonl}
REPLACE_EXISTING=${REPLACE_EXISTING:-no}
CLIENT_LAUNCHER_SMOKE=${CLIENT_LAUNCHER_SMOKE:-/tmp/cs-storage-production-client-launcher}

usage() {
  cat <<'EOF'
Usage: scripts/hd01-production-install.sh [options]

Production installer for hd01-style Swarm clusters. Defaults to dry-run.

Options:
  --apply                 Run write/deploy steps. Still requires ACK_* env vars.
  --dry-run               Force dry-run mode.
  --image IMAGE           Runtime image tag to build/deploy.
  --server-url URL        Public/internal gateway URL passed to C-side daemons.
  --server-port PORT      Published S-side gateway port, default 8080.
  --nodes-min N           Minimum Ready Swarm nodes required.
  --replace-existing      Replace existing cs-storage daemon/plugin containers and sockets.
  -h, --help              Show this help.

Required apply acknowledgements:
  ACK_PRODUCTION_INSTALL=yes
  ACK_INSTALL_HOST_DEPS=yes
  ACK_WRITE_PRODUCTION_SECRETS=yes

Required apply secrets:
  CS_NODE_SECRET_KEY
  CS_BACKEND_URL
  CS_BACKEND_AUTH_HEADER
    or CS_BACKEND_USER plus CS_BACKEND_PASSWORD
  CS_GOCRYPTFS_PASSWORD

Example:
  APPLY=1 ACK_PRODUCTION_INSTALL=yes ACK_INSTALL_HOST_DEPS=yes ACK_WRITE_PRODUCTION_SECRETS=yes \
  CS_NODE_SECRET_KEY=... CS_BACKEND_URL=... CS_BACKEND_USER=... CS_BACKEND_PASSWORD=... \
  CS_GOCRYPTFS_PASSWORD=... ./scripts/hd01-production-install.sh --server-url http://manager:8080
EOF
}

while test "$#" -gt 0; do
  case "$1" in
    --apply)
      APPLY=1
      ;;
    --dry-run)
      APPLY=0
      ;;
    --image)
      shift
      test "$#" -gt 0 || { echo "PRODUCTION_INSTALL_MISSING_ARG option=--image" >&2; exit 1; }
      IMAGE=$1
      ;;
    --server-url)
      shift
      test "$#" -gt 0 || { echo "PRODUCTION_INSTALL_MISSING_ARG option=--server-url" >&2; exit 1; }
      CS_SERVER_URL=$1
      ;;
    --server-port)
      shift
      test "$#" -gt 0 || { echo "PRODUCTION_INSTALL_MISSING_ARG option=--server-port" >&2; exit 1; }
      CS_SERVER_PORT=$1
      ;;
    --nodes-min)
      shift
      test "$#" -gt 0 || { echo "PRODUCTION_INSTALL_MISSING_ARG option=--nodes-min" >&2; exit 1; }
      NODES_MIN=$1
      ;;
    --replace-existing)
      REPLACE_EXISTING=yes
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "PRODUCTION_INSTALL_UNKNOWN_ARG arg=$1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

RUN_BUILD=${RUN_BUILD:-$APPLY}
RUN_RUNTIME_SMOKE=${RUN_RUNTIME_SMOKE:-$APPLY}
RUN_IMAGE_LOAD=${RUN_IMAGE_LOAD:-$APPLY}
RUN_PATH_PREPARE=${RUN_PATH_PREPARE:-$APPLY}
RUN_HOST_DEPS=${RUN_HOST_DEPS:-$APPLY}
RUN_SECRETS_BOOTSTRAP=${RUN_SECRETS_BOOTSTRAP:-$APPLY}
RUN_STACK_PLAN=${RUN_STACK_PLAN:-1}
RUN_DEPLOY=${RUN_DEPLOY:-1}
RUN_READINESS_GATE=${RUN_READINESS_GATE:-$APPLY}
READINESS_INCLUDE_ACCEPTANCE=${READINESS_INCLUDE_ACCEPTANCE:-0}

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

log() {
  printf '%s\n' "$*"
}

fail() {
  log "$*"
  exit 1
}

docker_t() {
  timeout "$DOCKER_TIMEOUT" docker "$@"
}

run_step() {
  name=$1
  shift
  log "PRODUCTION_INSTALL_STEP_BEGIN name=$name"
  "$@"
  log "PRODUCTION_INSTALL_STEP_OK name=$name"
}

require_repo() {
  test -s go.mod || fail "PRODUCTION_INSTALL_NOT_REPO missing=go.mod"
  test -s Dockerfile || fail "PRODUCTION_INSTALL_NOT_REPO missing=Dockerfile"
  test -s deploy/stack/cs-storage-server.yml || fail "PRODUCTION_INSTALL_NOT_REPO missing=deploy/stack/cs-storage-server.yml"
  test -x scripts/hd01-production-secrets-bootstrap.sh || fail "PRODUCTION_INSTALL_NOT_REPO missing_or_not_executable=scripts/hd01-production-secrets-bootstrap.sh"
}

require_swarm() {
  state=$(docker_t info --format '{{.Swarm.LocalNodeState}}')
  test "$state" = "active" || fail "PRODUCTION_INSTALL_SWARM_NOT_ACTIVE state=$state"
  ready=$(docker_t node ls --format '{{.Status}}' | awk '$1 == "Ready" {n++} END {print n+0}')
  if test -z "$NODES_MIN"; then
    NODES_MIN=$ready
    export NODES_MIN
  fi
  test "$ready" -ge "$NODES_MIN" || fail "PRODUCTION_INSTALL_NOT_ENOUGH_NODES ready=$ready min=$NODES_MIN"
  log "PRODUCTION_INSTALL_SWARM_OK ready=$ready min=$NODES_MIN"
}

infer_server_url() {
  if test -n "$CS_SERVER_URL"; then
    export CS_SERVER_URL
    return
  fi
  manager_addr=$(docker_t node inspect self --format '{{.Status.Addr}}' 2>/dev/null || true)
  if test -z "$manager_addr"; then
    manager_addr=$(hostname -I | awk '{print $1}')
  fi
  test -n "$manager_addr" || fail "PRODUCTION_INSTALL_CANNOT_INFER_SERVER_URL"
  CS_SERVER_URL="http://$manager_addr:$CS_SERVER_PORT"
  export CS_SERVER_URL
  log "PRODUCTION_INSTALL_INFERRED_SERVER_URL url=$CS_SERVER_URL"
}

require_apply_ack() {
  if test "$APPLY" = "1" && test "$ACK_PRODUCTION_INSTALL" != "yes"; then
    fail "PRODUCTION_INSTALL_REFUSE_APPLY missing_ack=ACK_PRODUCTION_INSTALL=yes"
  fi
}

require_secret_inputs_for_apply() {
  test "$APPLY" = "1" || return 0
  test "$RUN_SECRETS_BOOTSTRAP" = "1" || return 0
  missing=""
  for key in CS_NODE_SECRET_KEY CS_BACKEND_URL CS_SERVER_URL CS_GOCRYPTFS_PASSWORD; do
    eval "value=\${$key:-}"
    if test -z "$value"; then
      missing="$missing $key"
    fi
  done
  if test -z "${CS_BACKEND_AUTH_HEADER:-}"; then
    test -n "${CS_BACKEND_USER:-}" || missing="$missing CS_BACKEND_USER"
    test -n "${CS_BACKEND_PASSWORD:-}" || missing="$missing CS_BACKEND_PASSWORD"
  fi
  test -z "$missing" || fail "PRODUCTION_INSTALL_MISSING_SECRET_INPUTS keys=$missing"
}

build_image() {
  docker run --rm --network host -v "$PWD:/src" -w /src "$GO_IMAGE" sh -lc '
    set -eu
    /usr/local/go/bin/gofmt -w cmd internal
    /usr/local/go/bin/go test ./...
    /usr/local/go/bin/go build -buildvcs=false ./cmd/cs-storage-server ./cmd/cs-storage-daemon ./cmd/cs-storage-plugin ./cmd/cs-storage-admin ./cmd/cs-storage-router
  '
  # DOCKER_BUILD_ARGS is intentionally word-split so callers can pass flags such as: --network host --pull.
  docker build $DOCKER_BUILD_ARGS -t "$IMAGE" .
  log "HD01_DOCKER_BUILD_OK image=$IMAGE args=\"$DOCKER_BUILD_ARGS\""
}

run_runtime_smoke() {
  IMAGE="$IMAGE" DOCKER_BUILD_ARGS="$DOCKER_BUILD_ARGS" ./scripts/hd01-runtime-image-smoke.sh
}

load_image_to_nodes() {
  IMAGE="$IMAGE" NODES_MIN="$NODES_MIN" ./scripts/hd01-swarm-image-load-smoke.sh
}

prepare_paths() {
  IMAGE="$PROBE_IMAGE" NODES_MIN="$NODES_MIN" ./scripts/hd01-production-path-prepare.sh
  IMAGE="$PROBE_IMAGE" NODES_MIN="$NODES_MIN" STRICT=1 ./scripts/hd01-production-path-preflight.sh
}

rollout_host_deps() {
  IMAGE="$PROBE_IMAGE" NODES_MIN="$NODES_MIN" SMOKE=/tmp/cs-cluster-preflight-before-install ./scripts/hd01-cluster-preflight.sh || true
  IMAGE="$IMAGE" NODES_MIN="$NODES_MIN" APPLY="$APPLY" ACK_INSTALL_HOST_DEPS="$ACK_INSTALL_HOST_DEPS" PREFLIGHT_SMOKE=/tmp/cs-cluster-preflight-before-install ./scripts/hd01-cluster-deps-rollout.sh
  if test "$APPLY" = "1"; then
    IMAGE="$PROBE_IMAGE" NODES_MIN="$NODES_MIN" SMOKE=/tmp/cs-cluster-preflight-after-install STRICT=1 ./scripts/hd01-cluster-preflight.sh
  fi
}

bootstrap_secrets() {
  IMAGE="$PROBE_IMAGE" NODES_MIN="$NODES_MIN" APPLY="$APPLY" ACK_WRITE_PRODUCTION_SECRETS="$ACK_WRITE_PRODUCTION_SECRETS" CS_SERVER_URL="$CS_SERVER_URL" ./scripts/hd01-production-secrets-bootstrap.sh
  if test "$APPLY" = "1"; then
    IMAGE="$PROBE_IMAGE" NODES_MIN="$NODES_MIN" STRICT=1 ./scripts/hd01-production-secrets-preflight.sh
  fi
}

render_stack_plan() {
  IMAGE="$IMAGE" DUMMY=1 ./scripts/hd01-production-stack-plan.sh
  if test "$APPLY" = "1"; then
    IMAGE="$IMAGE" DUMMY=0 ./scripts/hd01-production-stack-plan.sh
  fi
}

wait_service_replicas() {
  service=$1
  min=$2
  for _ in $(seq 1 180); do
    running=$(docker_t service ps "$service" --filter desired-state=running --format '{{.CurrentState}}' 2>/dev/null | awk '$1 == "Running" {n++} END {print n+0}')
    if test "$running" -ge "$min"; then
      return 0
    fi
    sleep 1
  done
  docker_t service ps "$service" --no-trunc || true
  return 1
}

deploy_server_stack() {
  test -s "$SERVER_ENV" || fail "PRODUCTION_INSTALL_MISSING_SERVER_ENV path=$SERVER_ENV"
  set -a
  # shellcheck disable=SC1090
  . "$SERVER_ENV"
  set +a
  export CS_STORAGE_IMAGE="$IMAGE"
  export CS_SERVER_PORT
  docker_t stack deploy -c deploy/stack/cs-storage-server.yml "$SERVER_STACK"
  wait_service_replicas "${SERVER_STACK}_gateway" 1 || fail "PRODUCTION_INSTALL_SERVER_NOT_RUNNING stack=$SERVER_STACK"
  log "PRODUCTION_INSTALL_SERVER_STACK_OK stack=$SERVER_STACK image=$IMAGE port=$CS_SERVER_PORT"
}

deploy_client_launcher() {
  rm -rf "$CLIENT_LAUNCHER_SMOKE"
  mkdir -p "$CLIENT_LAUNCHER_SMOKE"
  cat > "$CLIENT_LAUNCHER_SMOKE/stack.yml" <<STACK_EOF
version: "3.8"
services:
  launcher:
    image: $LAUNCHER_IMAGE
    command:
      - sh
      - -c
      - |
        set -eu
        node_id=\$\$(docker info --format '{{.Name}}')
        issue=0
        if test "$REPLACE_EXISTING" != "yes"; then
          if docker ps -a --format '{{.Names}}' | grep -Fx "$DAEMON_CONTAINER" >/dev/null 2>&1; then
            echo "PRODUCTION_INSTALL_CLIENT_ISSUE node=\$\$node_id existing_container=$DAEMON_CONTAINER"
            issue=1
          fi
          if docker ps -a --format '{{.Names}}' | grep -Fx "$PLUGIN_CONTAINER" >/dev/null 2>&1; then
            echo "PRODUCTION_INSTALL_CLIENT_ISSUE node=\$\$node_id existing_container=$PLUGIN_CONTAINER"
            issue=1
          fi
          if test -S /host$DAEMON_SOCKET; then
            echo "PRODUCTION_INSTALL_CLIENT_ISSUE node=\$\$node_id existing_socket=$DAEMON_SOCKET"
            issue=1
          fi
          if test -S /host$PLUGIN_SOCKET; then
            echo "PRODUCTION_INSTALL_CLIENT_ISSUE node=\$\$node_id existing_socket=$PLUGIN_SOCKET"
            issue=1
          fi
        fi
        if test "\$\$issue" -ne 0; then
          echo "PRODUCTION_INSTALL_CLIENT_REFUSE_REPLACE node=\$\$node_id set=REPLACE_EXISTING=yes"
          exit 1
        fi
        test -s /host$DAEMON_ENV
        test -s /host$PLUGIN_ENV
        docker rm -f "$PLUGIN_CONTAINER" "$DAEMON_CONTAINER" >/dev/null 2>&1 || true
        rm -f /host$DAEMON_SOCKET /host$PLUGIN_SOCKET
        mkdir -p /host/run/docker/plugins /host$ROOT_DIR /host/var/log/cs-storage
        docker run -d --name "$DAEMON_CONTAINER" \
          --restart unless-stopped \
          --network host \
          --privileged \
          --cap-add SYS_ADMIN \
          --device /dev/fuse \
          --env-file /host$DAEMON_ENV \
          -e CS_NODE_ID="\$\$node_id" \
          -e CS_DAEMON_SOCKET="$DAEMON_SOCKET" \
          -e CS_ROOT_DIR="$ROOT_DIR" \
          -e CS_STATE_PATH="$ROOT_DIR/.state/volumes.json" \
          -e CS_AUDIT_LOG="$AUDIT_LOG" \
          -e CS_SERVER_URL="$CS_SERVER_URL" \
          -v /run:/run \
          -v "$ROOT_DIR:$ROOT_DIR:rshared" \
          -v /var/log/cs-storage:/var/log/cs-storage \
          -v /etc/cs-storage/secrets:/run/cs-storage-secrets:ro \
          --entrypoint /usr/bin/cs-storage-daemon \
          "$IMAGE" >/tmp/cs-storage-daemon.cid
        docker run -d --name "$PLUGIN_CONTAINER" \
          --restart unless-stopped \
          --env-file /host$PLUGIN_ENV \
          -e CS_PLUGIN_SOCKET="$PLUGIN_SOCKET" \
          -e CS_DAEMON_SOCKET="$DAEMON_SOCKET" \
          -v /run/docker/plugins:/run/docker/plugins \
          -v /run:/run \
          -v /var/run/docker.sock:/var/run/docker.sock \
          --entrypoint /usr/bin/cs-storage-plugin \
          "$IMAGE" >/tmp/cs-storage-plugin.cid
        i=0
        while test "\$\$i" -lt 240; do
          if test -S /host$DAEMON_SOCKET && test -S /host$PLUGIN_SOCKET; then
            break
          fi
          i=\$\$((i + 1))
          sleep 0.25
        done
        if ! test -S /host$DAEMON_SOCKET || ! test -S /host$PLUGIN_SOCKET; then
          echo "PRODUCTION_INSTALL_CLIENT_SOCKET_WAIT_FAILED node=\$\$node_id"
          echo DAEMON_LOGS
          docker logs "$DAEMON_CONTAINER" 2>&1 || true
          echo PLUGIN_LOGS
          docker logs "$PLUGIN_CONTAINER" 2>&1 || true
          exit 1
        fi
        echo "PRODUCTION_INSTALL_CLIENT_NODE_OK node=\$\$node_id daemon=$DAEMON_CONTAINER plugin=$PLUGIN_CONTAINER image=$IMAGE"
    volumes:
      - type: bind
        source: /
        target: /host
      - type: bind
        source: /var/run/docker.sock
        target: /var/run/docker.sock
    deploy:
      mode: global
      restart_policy:
        condition: none
STACK_EOF

  docker_t stack deploy -c "$CLIENT_LAUNCHER_SMOKE/stack.yml" "$CLIENT_STACK" >/dev/null
  service="${CLIENT_STACK}_launcher"
  ok=0
  completed=0
  issues=0
  failed=0
  for _ in $(seq 1 300); do
    docker_t service logs --raw --tail 1000 "$service" > "$CLIENT_LAUNCHER_SMOKE/logs.txt" 2>/dev/null || true
    docker_t service ps "$service" --no-trunc --format '{{.Node}}|{{.CurrentState}}|{{.Error}}' > "$CLIENT_LAUNCHER_SMOKE/service-ps.txt" 2>/dev/null || true
    ok=$(awk '$1 == "PRODUCTION_INSTALL_CLIENT_NODE_OK" {n++} END {print n+0}' "$CLIENT_LAUNCHER_SMOKE/logs.txt")
    completed=$(awk -F'|' '$2 ~ /^Complete/ {print $1}' "$CLIENT_LAUNCHER_SMOKE/service-ps.txt" | sort -u | wc -l | tr -d ' ')
    issues=$(awk '$1 ~ /^PRODUCTION_INSTALL_CLIENT_(ISSUE|REFUSE|SOCKET_WAIT_FAILED)/ {n++} END {print n+0}' "$CLIENT_LAUNCHER_SMOKE/logs.txt")
    failed=$(awk -F'|' '$2 ~ /^Failed|^Rejected/ || $3 != "" {n++} END {print n+0}' "$CLIENT_LAUNCHER_SMOKE/service-ps.txt")
    if test "$issues" -gt 0 || test "$failed" -gt 0 || test "$ok" -ge "$NODES_MIN" || test "$completed" -ge "$NODES_MIN"; then
      break
    fi
    sleep 1
  done
  cat "$CLIENT_LAUNCHER_SMOKE/logs.txt"
  if test "$issues" -gt 0 || test "$failed" -gt 0 || { test "$ok" -lt "$NODES_MIN" && test "$completed" -lt "$NODES_MIN"; }; then
    docker_t service ps "$service" --no-trunc || true
    fail "PRODUCTION_INSTALL_CLIENT_NOT_READY ok=$ok completed=$completed issues=$issues failed=$failed min=$NODES_MIN stack=$CLIENT_STACK"
  fi
  ready=$ok
  if test "$ready" -lt "$NODES_MIN"; then
    ready=$completed
    log "PRODUCTION_INSTALL_CLIENT_LOGS_PARTIAL ok_logs=$ok completed=$completed min=$NODES_MIN stack=$CLIENT_STACK"
  fi
  docker_t stack rm "$CLIENT_STACK" >/dev/null 2>&1 || true
  log "PRODUCTION_INSTALL_CLIENT_LAUNCHER_OK nodes=$ready image=$IMAGE replace=$REPLACE_EXISTING"
}

deploy_production() {
  test "$APPLY" = "1" || {
    log "PRODUCTION_INSTALL_DEPLOY_DRY_RUN server_stack=$SERVER_STACK client_stack=$CLIENT_STACK image=$IMAGE"
    return 0
  }
  deploy_server_stack
  deploy_client_launcher
}

run_readiness_gate() {
  RUN_ACCEPTANCE_AUDIT="$READINESS_INCLUDE_ACCEPTANCE" IMAGE="$IMAGE" PROBE_IMAGE="$PROBE_IMAGE" ./scripts/hd01-production-readiness-gate.sh
}

require_repo
require_apply_ack
require_swarm
infer_server_url
require_secret_inputs_for_apply

if test "$APPLY" != "1"; then
  log "PRODUCTION_INSTALL_DRY_RUN apply=0 image=$IMAGE nodes_min=$NODES_MIN"
  log "PRODUCTION_INSTALL_DRY_RUN_TO_APPLY set=APPLY=1 ACK_PRODUCTION_INSTALL=yes ACK_INSTALL_HOST_DEPS=yes ACK_WRITE_PRODUCTION_SECRETS=yes"
fi

test "$RUN_BUILD" = "1" && run_step build_image build_image
test "$RUN_RUNTIME_SMOKE" = "1" && run_step runtime_image_smoke run_runtime_smoke
test "$RUN_IMAGE_LOAD" = "1" && run_step image_load load_image_to_nodes
test "$RUN_PATH_PREPARE" = "1" && run_step path_prepare prepare_paths
test "$RUN_HOST_DEPS" = "1" && run_step host_deps rollout_host_deps
test "$RUN_SECRETS_BOOTSTRAP" = "1" && run_step secrets_bootstrap bootstrap_secrets
test "$RUN_STACK_PLAN" = "1" && run_step stack_plan render_stack_plan
test "$RUN_DEPLOY" = "1" && run_step deploy deploy_production
test "$RUN_READINESS_GATE" = "1" && run_step readiness_gate run_readiness_gate

log "PRODUCTION_INSTALL_OK apply=$APPLY image=$IMAGE server_stack=$SERVER_STACK client_stack=$CLIENT_STACK server_url=$CS_SERVER_URL"
