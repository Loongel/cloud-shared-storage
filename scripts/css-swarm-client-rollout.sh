#!/bin/sh
set -eu

STACK=${STACK:-css-client-rollout}
IMAGE=${IMAGE:-docker:27-cli}
HELPER_IMAGE=${HELPER_IMAGE:-alpine:3.20}
RUN_ID=${CSS_ROLLOUT_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}
SERVER_URL=${SERVER_URL:-}
NODE_SECRET_FILE=${NODE_SECRET_FILE:-/etc/cs-storage/secrets/node_secret}
CSS_RELEASE_VERSION=${CSS_RELEASE_VERSION:-0.1.7}
CSS_REPO_RAW=${CSS_REPO_RAW:-https://raw.githubusercontent.com/Loongel/cloud-shared-storage/main}
NODES_MIN=${NODES_MIN:-}
WORK=${WORK:-/tmp/css-swarm-client-rollout-$RUN_ID}
CLEANUP=${CLEANUP:-1}

usage() {
  cat <<EOF
Usage: scripts/css-swarm-client-rollout.sh [options]

Reinstall or upgrade the CSS client host services on every Ready Swarm node by
running the official client one-command installer inside each node's host root.
The production services remain host systemd services; this Swarm service is
only a temporary privileged rollout launcher.

Options:
  --server-url URL          CSS server URL. Defaults to local daemon.env.
  --node-secret-file FILE   Server node_secret file, default $NODE_SECRET_FILE.
  --release-version VER     GitHub Release version, default $CSS_RELEASE_VERSION.
  --stack NAME              Temporary stack name, default $STACK.
  --nodes-min N             Required completed node count, default Ready nodes.
  --no-cleanup              Leave rollout stack and Docker secret for debugging.
  -h, --help                Show this help.

Environment:
  CSS_REPO_RAW              Raw GitHub base URL, default $CSS_REPO_RAW.
  IMAGE                     Launcher image with docker CLI, default $IMAGE.
  HELPER_IMAGE              Privileged local helper image, default $HELPER_IMAGE.
EOF
}

while test "$#" -gt 0; do
  case "$1" in
    --server-url) shift; SERVER_URL=$1 ;;
    --node-secret-file) shift; NODE_SECRET_FILE=$1 ;;
    --release-version) shift; CSS_RELEASE_VERSION=$1 ;;
    --stack) shift; STACK=$1 ;;
    --nodes-min) shift; NODES_MIN=$1 ;;
    --no-cleanup) CLEANUP=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

docker_cmd() {
  if docker info >/dev/null 2>&1; then
    docker "$@"
  else
    sudo -n docker "$@"
  fi
}

read_env_value() {
  file=$1
  key=$2
  test -f "$file" || return 1
  awk -F= -v k="$key" '$1 == k {sub(/^[^=]*=/, ""); print; found=1; exit} END {exit found ? 0 : 1}' "$file"
}

cleanup() {
  if test "$CLEANUP" = "1"; then
    docker_cmd stack rm "$STACK" >/dev/null 2>&1 || true
    for _ in $(seq 1 60); do
      if ! docker_cmd stack ps "$STACK" >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done
    docker_cmd secret rm "$SECRET_NAME" >/dev/null 2>&1 || true
  fi
}

test "$(id -u)" = 0 || {
  echo "must run as root because this rollout enters host roots" >&2
  exit 1
}

if test -z "$SERVER_URL"; then
  SERVER_URL=$(read_env_value /etc/cs-storage/daemon.env CS_SERVER_URL || true)
fi
test -n "$SERVER_URL" || {
  echo "missing --server-url and no CS_SERVER_URL in /etc/cs-storage/daemon.env" >&2
  exit 1
}
test -s "$NODE_SECRET_FILE" || {
  echo "missing node secret file: $NODE_SECRET_FILE" >&2
  exit 1
}

state=$(docker_cmd info --format '{{.Swarm.LocalNodeState}}')
test "$state" = active || {
  echo "SWARM_NOT_ACTIVE state=$state" >&2
  exit 1
}
ready_nodes=$(docker_cmd node ls --format '{{.Status}}' | awk '$1 == "Ready" {n++} END {print n+0}')
if test -z "$NODES_MIN"; then
  NODES_MIN=$ready_nodes
fi
test "$ready_nodes" -ge "$NODES_MIN" || {
  echo "not enough Ready nodes: ready=$ready_nodes min=$NODES_MIN" >&2
  exit 1
}

SECRET_NAME="${STACK}-${RUN_ID}-node-secret"
rm -rf "$WORK"
mkdir -p "$WORK"
docker_cmd stack rm "$STACK" >/dev/null 2>&1 || true
docker_cmd secret rm "$SECRET_NAME" >/dev/null 2>&1 || true
docker_cmd secret create "$SECRET_NAME" "$NODE_SECRET_FILE" >/dev/null

trap cleanup EXIT INT TERM

cat > "$WORK/stack.yml" <<EOF
version: "3.8"
services:
  rollout:
    image: $IMAGE
    entrypoint:
      - /bin/sh
      - -c
    command:
      - |
        set -u
        node=\`cat /host/etc/hostname 2>/dev/null || hostname\`
        mkdir -p /host/var/log/cs-storage /host/tmp
        secret_host=/host/tmp/css-rollout-node-secret-$RUN_ID
        secret_chroot=/tmp/css-rollout-node-secret-$RUN_ID
        script_host=/host/tmp/css-rollout-install-client-$RUN_ID.sh
        script_chroot=/tmp/css-rollout-install-client-$RUN_ID.sh
        log=/host/var/log/cs-storage/css-client-rollout-$RUN_ID.log
        cp /run/secrets/node_secret "\$\$secret_host"
        chmod 0600 "\$\$secret_host"
        {
          printf '%s\n' '#!/bin/sh'
          printf '%s\n' 'set -eu'
          printf '%s\n' 'export CSS_RELEASE_VERSION="$CSS_RELEASE_VERSION"'
          printf '%s\n' 'export CSS_OUTPUT_COLOR=never'
          printf '%s\n' "curl -fsSL \"$CSS_REPO_RAW/scripts/css-install-client.sh\" | sh -s -- --server-url \"$SERVER_URL\" --node-secret-file \"\$\$secret_chroot\" --force-secret-update"
        } > "\$\$script_host"
        chmod 0700 "\$\$script_host"
        echo "CSS_CLIENT_ROLLOUT_BEGIN node=\$\$node server_url=$SERVER_URL release=$CSS_RELEASE_VERSION" | tee -a "\$\$log"
        if docker run --rm \\
          --privileged \\
          --pid host \\
          --network host \\
          -v /:/host \\
          $HELPER_IMAGE \\
          /bin/sh -c "chroot /host /bin/sh '\$\$script_chroot'" >> "\$\$log" 2>&1; then
          rc=0
        else
          rc=\$\$?
        fi
        rm -f "\$\$secret_host" "\$\$script_host"
        if test "\$\$rc" -eq 0; then
          echo "CSS_CLIENT_ROLLOUT_OK node=\$\$node" | tee -a "\$\$log"
        else
          echo "CSS_CLIENT_ROLLOUT_FAIL node=\$\$node rc=\$\$rc" | tee -a "\$\$log"
        fi
        exit "\$\$rc"
    secrets:
      - source: node_secret
        target: node_secret
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
secrets:
  node_secret:
    external: true
    name: $SECRET_NAME
EOF

docker_cmd stack deploy -c "$WORK/stack.yml" "$STACK" >/dev/null
service="${STACK}_rollout"
for _ in $(seq 1 1800); do
  docker_cmd service ps "$service" --no-trunc --format '{{.Node}}|{{.CurrentState}}|{{.Error}}' > "$WORK/service-ps.txt" 2>/dev/null || true
  completed=$(awk -F'|' '$2 ~ /^Complete/ {print $1}' "$WORK/service-ps.txt" | sort -u | wc -l | tr -d ' ')
  failed=$(awk -F'|' '$2 ~ /^Failed|^Rejected/ || $3 != "" {n++} END {print n+0}' "$WORK/service-ps.txt")
  test "$completed" -ge "$NODES_MIN" && break
  test "$failed" -gt 0 && break
  sleep 2
done

docker_cmd service logs --raw "$service" > "$WORK/logs.txt" 2>&1 || true
docker_cmd service ps "$service" --no-trunc --format '{{.Node}}|{{.CurrentState}}|{{.Error}}' > "$WORK/service-ps.txt" 2>/dev/null || true
cat "$WORK/logs.txt"
completed=$(awk -F'|' '$2 ~ /^Complete/ {print $1}' "$WORK/service-ps.txt" | sort -u | wc -l | tr -d ' ')
failed=$(awk -F'|' '$2 ~ /^Failed|^Rejected/ || $3 != "" {n++} END {print n+0}' "$WORK/service-ps.txt")
ok_logs=$(awk '$1 == "CSS_CLIENT_ROLLOUT_OK" {n++} END {print n+0}' "$WORK/logs.txt")
if test "$completed" -lt "$NODES_MIN" || test "$failed" -gt 0; then
  docker_cmd service ps "$service" --no-trunc || true
  echo "CSS_SWARM_CLIENT_ROLLOUT_FAILED completed=$completed ok_logs=$ok_logs failed=$failed min=$NODES_MIN ready=$ready_nodes logs=$WORK/logs.txt" >&2
  exit 1
fi

echo "CSS_SWARM_CLIENT_ROLLOUT_OK completed=$completed ok_logs=$ok_logs min=$NODES_MIN ready=$ready_nodes logs=$WORK/logs.txt"
