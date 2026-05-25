#!/bin/sh
set -eu

STACK=${STACK:-css_scenario}
RUN_ID=${CSS_TEST_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}
SETTLE_SECONDS=${CSS_TEST_SETTLE_SECONDS:-20}
TIMEOUT=${CSS_TEST_TIMEOUT:-240}
CSS_REPO_RAW=${CSS_REPO_RAW:-https://raw.githubusercontent.com/Loongel/cloud-shared-storage/main}
STACK_FILE=${STACK_FILE:-}
LABEL_MODE=current
CLEAN=0
REPORT=1
ENABLE_BACKUP=0
ENABLE_SQLITE=0
CLEAR_LABELS=0
NODES=""
TMP_ROOT=""

usage() {
  cat <<'EOF'
Usage: scripts/css-scenario-test-deploy.sh [options]

Deploy the CSS formal Swarm scenario test stack. The stack uses the host
systemd `css` Docker VolumeDriver; it does not run CS-Storage as a container.

Options:
  --stack NAME              Stack name, default css_scenario.
  --run-id ID               Test run id, default UTC timestamp.
  --settle-seconds N        Seconds each workload waits before reporting, default 20.
  --timeout SECONDS         Report wait timeout, default 240.
  --current-node            Label only this Swarm node for testing, default.
  --all-ready-nodes         Label every Ready Swarm node for testing.
  --node NODE               Label a specific node for testing; repeatable.
  --enable-backup           Also run cs.backup=auto scenario on labelled nodes.
  --enable-sqlite           Also run shared+multi+sqlite probe on labelled nodes.
  --clean                   Remove the previous stack and known test volumes first.
  --clear-labels            Remove css.test.* labels from selected nodes after deploy/report.
  --no-report               Deploy only; do not run the report script.
  -h, --help                Show help.

By default only the current node receives node.labels.css.test.enabled=true.
Use --all-ready-nodes after every target node has the host services installed.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --stack) shift; STACK=$1 ;;
    --run-id) shift; RUN_ID=$1 ;;
    --settle-seconds) shift; SETTLE_SECONDS=$1 ;;
    --timeout) shift; TIMEOUT=$1 ;;
    --current-node) LABEL_MODE=current ;;
    --all-ready-nodes) LABEL_MODE=all ;;
    --node) shift; LABEL_MODE=explicit; NODES="${NODES}${NODES:+ }$1" ;;
    --enable-backup) ENABLE_BACKUP=1 ;;
    --enable-sqlite) ENABLE_SQLITE=1 ;;
    --clean) CLEAN=1 ;;
    --clear-labels) CLEAR_LABELS=1 ;;
    --no-report) REPORT=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

download_file() {
  url=$1
  dst=$2
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dst"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$dst" "$url"
  else
    echo "missing curl or wget to fetch scenario test resources" >&2
    exit 1
  fi
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -f "$SCRIPT_DIR/../deploy/stack/css-scenario-test.yml" ] && [ -f "$SCRIPT_DIR/css-scenario-test-report.sh" ]; then
  ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
else
  TMP_ROOT=$(mktemp -d /tmp/css-scenario-test.XXXXXX)
  ROOT=$TMP_ROOT
  mkdir -p "$ROOT/deploy/stack" "$ROOT/deploy/scenario-test" "$ROOT/scripts"
  download_file "$CSS_REPO_RAW/deploy/stack/css-scenario-test.yml" "$ROOT/deploy/stack/css-scenario-test.yml"
  download_file "$CSS_REPO_RAW/deploy/scenario-test/workload.sh" "$ROOT/deploy/scenario-test/workload.sh"
  download_file "$CSS_REPO_RAW/scripts/css-scenario-test-report.sh" "$ROOT/scripts/css-scenario-test-report.sh"
  chmod 0755 "$ROOT/deploy/scenario-test/workload.sh" "$ROOT/scripts/css-scenario-test-report.sh"
fi
if [ -z "$STACK_FILE" ]; then
  STACK_FILE="$ROOT/deploy/stack/css-scenario-test.yml"
fi
cd "$ROOT"

docker_cmd() {
  if docker info >/dev/null 2>&1; then
    docker "$@"
  else
    sudo -n docker "$@"
  fi
}

label_node() {
  node=$1
  docker_cmd node update --label-add css.test.enabled=true "$node" >/dev/null
  if [ "$ENABLE_BACKUP" = "1" ]; then
    docker_cmd node update --label-add css.test.backup=true "$node" >/dev/null
  fi
  if [ "$ENABLE_SQLITE" = "1" ]; then
    docker_cmd node update --label-add css.test.sqlite=true "$node" >/dev/null
  fi
}

clear_node_labels() {
  node=$1
  for label in css.test.enabled css.test.backup css.test.sqlite; do
    docker_cmd node update --label-rm "$label" "$node" >/dev/null 2>&1 || true
  done
}

cleanup() {
  if [ "$CLEAR_LABELS" = "1" ] && [ -n "${NODES:-}" ]; then
    for node in $NODES; do
      clear_node_labels "$node"
    done
  fi
  if [ -n "$TMP_ROOT" ]; then
    rm -rf "$TMP_ROOT"
  fi
}
trap cleanup EXIT INT TERM

case "$LABEL_MODE" in
  current)
    current=$(docker_cmd info --format '{{.Swarm.NodeID}}')
    [ -n "$current" ] || { echo "this Docker engine is not a Swarm node" >&2; exit 1; }
    NODES=$current
    ;;
  all)
    NODES=$(docker_cmd node ls --filter status=ready --format '{{.ID}}' | tr '\n' ' ')
    ;;
  explicit) ;;
esac

[ -n "$NODES" ] || { echo "no nodes selected for css scenario test" >&2; exit 1; }

for node in $NODES; do
  label_node "$node"
done

if [ "$CLEAN" = "1" ]; then
  docker_cmd stack rm "$STACK" >/dev/null 2>&1 || true
  i=0
  while [ -n "$(docker_cmd stack services --format '{{.Name}}' "$STACK" 2>/dev/null || true)" ]; do
    i=$((i + 1))
    [ "$i" -le 60 ] || break
    sleep 1
  done
  for vol in \
    css_private_plain css_private_encrypted \
    css_shared_single_plain css_shared_single_encrypted \
    css_backup_auto_plain css_shared_multi_sqlite_probe; do
    docker_cmd volume rm "${STACK}_${vol}" >/dev/null 2>&1 || true
  done
fi

EXPECT_NODES=$(printf '%s\n' $NODES | sed '/^$/d' | wc -l | tr -d ' ')
echo "CSS_SCENARIO_DEPLOY stack=$STACK run_id=$RUN_ID nodes=$EXPECT_NODES settle_seconds=$SETTLE_SECONDS"

export CSS_TEST_RUN_ID=$RUN_ID
export CSS_TEST_EXPECT_NODES=$EXPECT_NODES
export CSS_TEST_SETTLE_SECONDS=$SETTLE_SECONDS
docker_cmd stack deploy -c "$STACK_FILE" "$STACK"

if [ "$REPORT" = "1" ]; then
  "$ROOT/scripts/css-scenario-test-report.sh" --stack "$STACK" --run-id "$RUN_ID" --timeout "$TIMEOUT"
fi
