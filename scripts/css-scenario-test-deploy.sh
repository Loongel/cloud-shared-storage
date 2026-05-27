#!/bin/sh
set -eu

STACK=${STACK:-css_scenario}
RUN_ID=${CSS_TEST_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}
TIMEOUT=${CSS_TEST_TIMEOUT:-240}
VERIFY_TIMEOUT=${CSS_TEST_VERIFY_TIMEOUT:-60}
FLUSH_SETTLE_SECONDS=${CSS_TEST_FLUSH_SETTLE_SECONDS:-10}
PROFILE=${CSS_TEST_PROFILE:-full}
CSS_REPO_RAW=${CSS_REPO_RAW:-https://raw.githubusercontent.com/Loongel/cloud-shared-storage/main}
STACK_FILE=${STACK_FILE:-}
SCENARIOS_FILE=${SCENARIOS_FILE:-}
LABEL_MODE=current
CLEAN=0
DOCKER_USE_SUDO=0
DOCKER_RETRY_ATTEMPTS=${DOCKER_RETRY_ATTEMPTS:-60}
DOCKER_RETRY_DELAY=${DOCKER_RETRY_DELAY:-5}
MAX_TASKS_PER_DEPLOY=${CSS_TEST_MAX_TASKS_PER_DEPLOY:-24}
ALLOW_LARGE_DEPLOY=${CSS_TEST_ALLOW_LARGE_DEPLOY:-0}
ALLOW_UNSTABLE_SWARM=${CSS_TEST_ALLOW_UNSTABLE_SWARM:-0}
REPORT=1
ENABLE_BACKUP=0
ENABLE_SQLITE=0
CLEAR_LABELS=0
PREFLIGHT=1
NODES=""
TMP_ROOT=""
RENDERED_STACK=""
OUT_DIR=""

usage() {
  cat <<'EOF'
Usage: scripts/css-scenario-test-deploy.sh [options]

Deploy the CSS formal Swarm scenario test stack. The stack uses the host
systemd `css` Docker VolumeDriver; it does not run CS-Storage as a container.

Options:
  --stack NAME              Stack name, default css_scenario.
  --run-id ID               Test run id, default UTC timestamp.
  --profile PROFILE         full, core, smoke, backup-only, or shared-multi-only. Default full.
  --verify-timeout N        Seconds each workload polls for expected state, default 60.
  --flush-settle-seconds N  Seconds to keep mount alive after writes, default 10.
  --timeout SECONDS         Report wait timeout, default 240.
  --current-node            Label only this Swarm node for testing, default.
  --all-ready-nodes         Label every Ready Swarm node for testing.
  --node NODE               Label a specific node for testing; repeatable.
  --enable-backup           Also run backup=true scenario on labelled nodes.
  --enable-sqlite           Also run shared+multi+sqlite probe on labelled nodes.
  --clean                   Remove the previous stack and known test volumes first.
  --clear-labels            Remove css.test.* labels from selected nodes after deploy/report.
  --no-preflight            Skip host/service/backend preflight probes.
  --scenarios-file FILE     Render only scenarios from this TSV file.
  --max-tasks-per-deploy N  Refuse deploys larger than N service-node tasks, default 24.
  --allow-large-deploy      Allow a deploy above --max-tasks-per-deploy.
  --allow-unstable-swarm    Skip recent Swarm/memberlist instability gate.
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
    --profile) shift; PROFILE=$1 ;;
    --verify-timeout) shift; VERIFY_TIMEOUT=$1 ;;
    --settle-seconds) shift; FLUSH_SETTLE_SECONDS=$1 ;;
    --flush-settle-seconds) shift; FLUSH_SETTLE_SECONDS=$1 ;;
    --timeout) shift; TIMEOUT=$1 ;;
    --current-node) LABEL_MODE=current ;;
    --all-ready-nodes) LABEL_MODE=all ;;
    --node) shift; LABEL_MODE=explicit; NODES="${NODES}${NODES:+ }$1" ;;
    --enable-backup) ENABLE_BACKUP=1 ;;
    --enable-sqlite) ENABLE_SQLITE=1 ;;
    --clean) CLEAN=1 ;;
    --clear-labels) CLEAR_LABELS=1 ;;
    --no-preflight) PREFLIGHT=0 ;;
    --scenarios-file) shift; SCENARIOS_FILE=$1 ;;
    --max-tasks-per-deploy) shift; MAX_TASKS_PER_DEPLOY=$1 ;;
    --allow-large-deploy) ALLOW_LARGE_DEPLOY=1 ;;
    --allow-unstable-swarm) ALLOW_UNSTABLE_SWARM=1 ;;
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
  download_file "$CSS_REPO_RAW/deploy/scenario-test/scenarios.tsv" "$ROOT/deploy/scenario-test/scenarios.tsv"
  download_file "$CSS_REPO_RAW/deploy/scenario-test/render-stack.sh" "$ROOT/deploy/scenario-test/render-stack.sh"
  download_file "$CSS_REPO_RAW/deploy/scenario-test/workload.sh" "$ROOT/deploy/scenario-test/workload.sh"
  download_file "$CSS_REPO_RAW/scripts/css-scenario-test-report.sh" "$ROOT/scripts/css-scenario-test-report.sh"
  chmod 0755 "$ROOT/deploy/scenario-test/render-stack.sh" "$ROOT/deploy/scenario-test/workload.sh" "$ROOT/scripts/css-scenario-test-report.sh"
fi
cd "$ROOT"

docker_cmd() {
  if [ "$DOCKER_USE_SUDO" = "1" ]; then
    sudo -n docker "$@"
  else
    docker "$@"
  fi
}

docker_cmd_retry() {
  i=1
  while :; do
    set +e
    out=$(docker_cmd "$@" 2>&1)
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
      printf '%s' "$out"
      return 0
    fi
    case "$out" in
      *"swarm does not have a leader"*|*"DeadlineExceeded"*|*"context deadline exceeded"*|*"rpc error"*)
        ;;
      *)
        printf '%s\n' "$out" >&2
        return "$rc"
        ;;
    esac
    if [ "$i" -ge "$DOCKER_RETRY_ATTEMPTS" ]; then
      printf '%s\n' "$out" >&2
      return "$rc"
    fi
    echo "CSS_DOCKER_RETRY attempt=$i cmd=docker $*" >&2
    i=$((i + 1))
    sleep "$DOCKER_RETRY_DELAY"
  done
}

cleanup_legacy_driver_artifacts() {
  rm -f \
    /run/docker/plugins/cs-storage.sock \
    /etc/docker/plugins/cs-storage.spec \
    /etc/docker/plugins/cs-storage.json
}

label_node() {
  node=$1
  node_update "$node" --label-add css.test.enabled=true
  if [ "$ENABLE_BACKUP" = "1" ]; then
    node_update "$node" --label-add css.test.backup=true
  fi
  if [ "$ENABLE_SQLITE" = "1" ]; then
    node_update "$node" --label-add css.test.sqlite=true
  fi
}

clear_node_labels() {
  node=$1
  for label in css.test.enabled css.test.backup css.test.sqlite; do
    docker_cmd_retry node update --label-rm "$label" "$node" >/dev/null 2>&1 || true
  done
}

clear_all_test_labels() {
  for node in $(docker_cmd_retry node ls -q); do
    clear_node_labels "$node"
  done
}

scenario_volume_names() {
  scenarios=${SCENARIOS_FILE:-$ROOT/deploy/scenario-test/scenarios.tsv}
  awk 'NR > 1 {print $1}' "$scenarios" | while read -r sid; do
    [ -n "$sid" ] || continue
    printf '%s\n' "${STACK}_css_${sid}"
  done
}

remove_old_stack_state() {
  docker_cmd stack rm "$STACK" >/dev/null 2>&1 || true
  i=0
  while [ -n "$(docker_cmd stack services --format '{{.Name}}' "$STACK" 2>/dev/null || true)" ]; do
    i=$((i + 1))
    [ "$i" -le 60 ] || break
    sleep 1
  done
  ids=$(docker_cmd ps -aq --filter "name=${STACK}_" 2>/dev/null || true)
  if [ -n "$ids" ]; then
    # shellcheck disable=SC2086
    docker_cmd rm -f $ids >/dev/null 2>&1 || true
  fi
  scenario_volume_names | while read -r vol; do
    [ -n "$vol" ] || continue
    docker_cmd volume rm "$vol" >/dev/null 2>&1 || true
  done
}

read_env_value() {
  file=$1
  key=$2
  [ -f "$file" ] || return 1
  awk -F= -v k="$key" '$1 == k {sub(/^[^=]*=/, ""); print; found=1; exit} END {exit found ? 0 : 1}' "$file"
}

tool_version() {
  tool=$1
  shift
  if ! command -v "$tool" >/dev/null 2>&1; then
    return 1
  fi
  for args in "$@"; do
    # shellcheck disable=SC2086
    if out=$("$tool" $args 2>&1 | sed -n '1p'); then
      [ -n "$out" ] && { printf '%s' "$out"; return 0; }
    fi
  done
  command -v "$tool"
}

runtime_tool_version() {
  env_key=$1
  fallback=$2
  shift 2
  configured=$(read_env_value /etc/cs-storage/daemon.env "$env_key" 2>/dev/null || true)
  for tool in "$configured" "$fallback" "$(basename "$fallback")"; do
    [ -n "$tool" ] || continue
    if note=$(tool_version "$tool" "$@"); then
      printf '%s' "$note"
      return 0
    fi
  done
  return 1
}

run_preflight() {
  out_dir=$1
  mkdir -p "$out_dir"
  pf="$out_dir/preflight.tsv"
  printf 'check\ttarget\tstatus\tnotes\n' > "$pf"

  for svc in cs-storage-server.service cs-storage-daemon.service cs-storage-plugin.service; do
    if systemctl is-active --quiet "$svc"; then
      printf 'systemd\t%s\tPASS\tactive\n' "$svc" >> "$pf"
    else
      printf 'systemd\t%s\tFAIL\tnot_active\n' "$svc" >> "$pf"
    fi
  done

  pkg_version=$(dpkg-query -W -f='${Version}' cs-storage 2>/dev/null || true)
  if [ -n "$pkg_version" ]; then
    printf 'package\tcs-storage\tPASS\tversion=%s\n' "$pkg_version" >> "$pf"
  else
    printf 'package\tcs-storage\tFAIL\tnot_installed_by_dpkg\n' >> "$pf"
  fi

  if note=$(runtime_tool_version CS_LITEFS_BINARY /usr/lib/cs-storage/bin/litefs version -version --version); then
    printf 'runtime-tool\tlitefs\tPASS\t%s\n' "$note" >> "$pf"
  else
    printf 'runtime-tool\tlitefs\tFAIL\tmissing_from_host_path\n' >> "$pf"
  fi
  if note=$(runtime_tool_version CS_KOPIA_BINARY /usr/lib/cs-storage/bin/kopia --version version); then
    printf 'runtime-tool\tkopia\tPASS\t%s\n' "$note" >> "$pf"
  else
    printf 'runtime-tool\tkopia\tFAIL\tmissing_from_host_path\n' >> "$pf"
  fi
  if note=$(tool_version mount.glusterfs --version -V); then
    printf 'runtime-tool\tmount.glusterfs\tPASS\t%s\n' "$note" >> "$pf"
  else
    printf 'runtime-tool\tmount.glusterfs\tFAIL\tmissing_from_host_path\n' >> "$pf"
  fi
  if systemctl list-unit-files glusterd.service >/dev/null 2>&1; then
    if systemctl is-active --quiet glusterd.service; then
      printf 'systemd\tglusterd.service\tPASS\tactive\n' >> "$pf"
    else
      printf 'systemd\tglusterd.service\tBLOCKED\tnot_active_required_for_local_gluster_server\n' >> "$pf"
    fi
  else
    printf 'systemd\tglusterd.service\tBLOCKED\tunit_missing_required_for_local_gluster_server\n' >> "$pf"
  fi

  gluster_remote=$(read_env_value /etc/cs-storage/daemon.env CS_GLUSTER_REMOTE 2>/dev/null || true)
  litefs_advertise=$(read_env_value /etc/cs-storage/daemon.env CS_LITEFS_ADVERTISE_URL 2>/dev/null || true)
  litefs_lease=$(read_env_value /etc/cs-storage/daemon.env CS_LITEFS_LEASE_TYPE 2>/dev/null || true)
  [ -n "$litefs_lease" ] || litefs_lease=static
  if [ -n "$gluster_remote" ]; then
    printf 'daemon-config\tCS_GLUSTER_REMOTE\tPASS\tconfigured\n' >> "$pf"
  else
    printf 'daemon-config\tCS_GLUSTER_REMOTE\tBLOCKED\tmissing_for_shared_multi_static_auto\n' >> "$pf"
  fi
  if [ -n "$litefs_advertise" ]; then
    printf 'daemon-config\tCS_LITEFS_ADVERTISE_URL\tPASS\tconfigured\n' >> "$pf"
  else
    printf 'daemon-config\tCS_LITEFS_ADVERTISE_URL\tBLOCKED\tmissing_for_shared_multi_sqlite_auto\n' >> "$pf"
  fi
  printf 'daemon-config\tCS_LITEFS_LEASE_TYPE\tPASS\t%s\n' "$litefs_lease" >> "$pf"

  if [ -S /run/docker/plugins/css.sock ]; then
    printf 'socket\t/run/docker/plugins/css.sock\tPASS\texists\n' >> "$pf"
  else
    printf 'socket\t/run/docker/plugins/css.sock\tFAIL\tmissing\n' >> "$pf"
  fi
  cleanup_legacy_driver_artifacts
  if [ -e /run/docker/plugins/cs-storage.sock ] || [ -e /etc/docker/plugins/cs-storage.spec ] || [ -e /etc/docker/plugins/cs-storage.json ]; then
    printf 'legacy-driver\tcs-storage\tFAIL\tlegacy_artifact_still_exists\n' >> "$pf"
  else
    printf 'legacy-driver\tcs-storage\tPASS\tremoved\n' >> "$pf"
  fi

  daemon_node=$(read_env_value /etc/cs-storage/daemon.env CS_NODE_ID 2>/dev/null || true)
  [ -n "$daemon_node" ] || daemon_node=unknown
  printf 'identity\tCS_NODE_ID\tPASS\t%s\n' "$daemon_node" >> "$pf"

  if curl -fsS --connect-timeout 3 --max-time 5 "$(read_env_value /etc/cs-storage/daemon.env CS_SERVER_URL 2>/dev/null || printf 'http://127.0.0.1:18080')/healthz" >/dev/null 2>&1; then
    printf 'server-health\tCS_SERVER_URL\tPASS\thealthz_ok\n' >> "$pf"
  else
    printf 'server-health\tCS_SERVER_URL\tFAIL\thealthz_failed\n' >> "$pf"
  fi

  base=$(printf '%s' "$RUN_ID" | tr -c 'A-Za-z0-9_.-' '_')
  for crypt in false true; do
    vol="css_preflight_${base}_${crypt}"
    if docker_cmd volume create -d css -o cs.mode=private -o cs.write=single -o cs.engine=auto -o cs.crypt="$crypt" -o cs.backup=false -o flush=true "$vol" >/tmp/css-preflight.$$ 2>&1; then
      if docker_cmd run --rm -v "$vol:/data" busybox:1.36 sh -c 'set -eu; mkdir -p /data/preflight; echo ok > /data/preflight/probe.txt; test "$(cat /data/preflight/probe.txt)" = ok' >/tmp/css-preflight.$$ 2>&1; then
        printf 'volume-rw\t%s\tPASS\tcrypt=%s\n' "$vol" "$crypt" >> "$pf"
      else
        note=$(tr '\n' ' ' < /tmp/css-preflight.$$ | sed 's/[[:space:]]\+/ /g')
        printf 'volume-rw\t%s\tFAIL\tcrypt=%s %s\n' "$vol" "$crypt" "$note" >> "$pf"
      fi
    else
      note=$(tr '\n' ' ' < /tmp/css-preflight.$$ | sed 's/[[:space:]]\+/ /g')
      printf 'volume-create\t%s\tFAIL\tcrypt=%s %s\n' "$vol" "$crypt" "$note" >> "$pf"
    fi
    docker_cmd volume rm "$vol" >/dev/null 2>&1 || true
  done
  rm -f /tmp/css-preflight.$$
  echo "CSS_SCENARIO_PREFLIGHT file=$pf"
}

node_update() {
  node=$1
  shift
  i=0
  while :; do
    if docker_cmd_retry node update "$@" "$node" >/dev/null; then
      return 0
    fi
    i=$((i + 1))
    [ "$i" -lt 6 ] || return 1
    sleep "$i"
  done
}

selected_nodes_ready() {
  for node in $NODES; do
    state=$(docker_cmd_retry node inspect --format '{{.Status.State}}' "$node" 2>/dev/null || true)
    msg=$(docker_cmd_retry node inspect --format '{{.Status.Message}}' "$node" 2>/dev/null || true)
    if [ "$state" != ready ]; then
      echo "CSS_SWARM_UNSTABLE node=$node state=$state message=$msg" >&2
      return 1
    fi
  done
}

cluster_nodes_ready() {
  bad=$(docker_cmd_retry node ls --format '{{.Hostname}}\t{{.Status}}\t{{.ManagerStatus}}' |
    awk -F '\t' '$2 != "Ready" {print $1 ":" $2 ":" $3}')
  if [ -n "$bad" ]; then
    printf '%s\n' "$bad" | sed 's/^/CSS_SWARM_UNSTABLE cluster_node=/' >&2
    return 1
  fi
}

recent_swarm_instability() {
  command -v journalctl >/dev/null 2>&1 || return 1
  journalctl -u docker --since '3 minutes ago' --no-pager 2>/dev/null |
    grep -E 'swarm does not have a leader|heartbeat failure|memberlist: .*UDP probes failed|memberlist: Failed fallback TCP ping|unknown to memberlist|Bulk sync to node .* timed out|node is no longer leader|raft proposal dropped' |
    sed -n '1,12p'
}

swarm_stability_preflight() {
  cluster_nodes_ready || return 1
  selected_nodes_ready || return 1
  if [ "$ALLOW_UNSTABLE_SWARM" = "1" ]; then
    return 0
  fi
  recent=$(recent_swarm_instability || true)
  if [ -n "$recent" ]; then
    printf '%s\n' "$recent" >&2
    echo "CSS_SWARM_UNSTABLE recent_docker_memberlist_or_raft_errors=1" >&2
    echo "Wait for Swarm to become quiet, run a smaller profile, or pass --allow-unstable-swarm only for diagnostics." >&2
    return 1
  fi
}

count_rendered_scenarios() {
  grep -c '^    driver: css$' "$STACK_FILE" 2>/dev/null || echo 0
}

guard_deploy_size() {
  scenario_count=$(count_rendered_scenarios)
  expected_tasks=$((scenario_count * EXPECT_NODES))
  if [ "$ALLOW_LARGE_DEPLOY" = "1" ]; then
    echo "CSS_SCENARIO_DEPLOY_SIZE scenarios=$scenario_count nodes=$EXPECT_NODES expected_tasks=$expected_tasks max=$MAX_TASKS_PER_DEPLOY allow_large=1"
    return 0
  fi
  if [ "$expected_tasks" -gt "$MAX_TASKS_PER_DEPLOY" ]; then
    cat >&2 <<EOF
CSS_SCENARIO_DEPLOY_REFUSED_TOO_LARGE scenarios=$scenario_count nodes=$EXPECT_NODES expected_tasks=$expected_tasks max=$MAX_TASKS_PER_DEPLOY
This guard prevents one test run from creating too many Swarm global tasks and
overlay endpoints at once. Run a smaller profile, select fewer nodes, increase
--max-tasks-per-deploy after Swarm is stable, or pass --allow-large-deploy only
for controlled diagnostics.
EOF
    return 1
  fi
  echo "CSS_SCENARIO_DEPLOY_SIZE scenarios=$scenario_count nodes=$EXPECT_NODES expected_tasks=$expected_tasks max=$MAX_TASKS_PER_DEPLOY"
}

cleanup() {
  if [ "$CLEAR_LABELS" = "1" ]; then
    clear_all_test_labels
  fi
  if [ -n "$TMP_ROOT" ]; then
    rm -rf "$TMP_ROOT"
  fi
  if [ -n "$RENDERED_STACK" ]; then
    rm -f "$RENDERED_STACK"
  fi
}
trap cleanup EXIT INT TERM

if docker info >/dev/null 2>&1; then
  DOCKER_USE_SUDO=0
else
  DOCKER_USE_SUDO=1
fi
cleanup_legacy_driver_artifacts

case "$LABEL_MODE" in
  current)
    current=$(docker_cmd_retry info --format '{{.Swarm.NodeID}}')
    [ -n "$current" ] || { echo "this Docker engine is not a Swarm node" >&2; exit 1; }
    NODES=$current
    ;;
  all)
    NODES=$(docker_cmd_retry node ls --format '{{.ID}}\t{{.Status}}' | awk -F '\t' '$2 == "Ready" {print $1}' | tr '\n' ' ')
    ;;
  explicit) ;;
esac

[ -n "$NODES" ] || { echo "no nodes selected for css scenario test" >&2; exit 1; }

NODE_NAMES=$(
  for node in $NODES; do
    docker_cmd_retry node inspect --format '{{.Description.Hostname}}' "$node"
    printf '\n'
  done | sort | tr '\n' ',' | sed 's/,$//'
)
WRITER_NODE=$(printf '%s\n' "$NODE_NAMES" | tr ',' '\n' | sed '/^$/d' | sort | sed -n '1p')
EXPECT_NODES=$(printf '%s\n' "$NODE_NAMES" | tr ',' '\n' | sed '/^$/d' | wc -l | tr -d ' ')

if [ -z "$STACK_FILE" ]; then
  RENDERED_STACK=$(mktemp /tmp/css-scenario-stack.XXXXXX.yml)
  render_args="--profile $PROFILE --workload-file $ROOT/deploy/scenario-test/workload.sh --out $RENDERED_STACK"
  if [ -n "$SCENARIOS_FILE" ]; then
    render_args="$render_args --scenarios $SCENARIOS_FILE"
  fi
  # shellcheck disable=SC2086
  sh "$ROOT/deploy/scenario-test/render-stack.sh" $render_args
  STACK_FILE=$RENDERED_STACK
fi

OUT_DIR=${OUT_DIR:-reports/css-scenario-$RUN_ID}

swarm_stability_preflight
guard_deploy_size

clear_all_test_labels

for node in $NODES; do
  label_node "$node"
done

if [ "$CLEAN" = "1" ]; then
  remove_old_stack_state
fi

if [ "$PREFLIGHT" = "1" ]; then
  run_preflight "$OUT_DIR"
fi

echo "CSS_SCENARIO_DEPLOY stack=$STACK run_id=$RUN_ID profile=$PROFILE nodes=$EXPECT_NODES node_names=$NODE_NAMES writer_node=$WRITER_NODE verify_timeout=$VERIFY_TIMEOUT flush_settle_seconds=$FLUSH_SETTLE_SECONDS"

export CSS_TEST_RUN_ID=$RUN_ID
export CSS_TEST_PROFILE=$PROFILE
export CSS_TEST_NODE_NAMES=$NODE_NAMES
export CSS_TEST_EXPECT_NODES=$EXPECT_NODES
export CSS_TEST_WRITER_NODE=$WRITER_NODE
export CSS_TEST_VERIFY_TIMEOUT=$VERIFY_TIMEOUT
export CSS_TEST_FLUSH_SETTLE_SECONDS=$FLUSH_SETTLE_SECONDS
docker_cmd_retry stack deploy -c "$STACK_FILE" "$STACK"

if [ "$REPORT" = "1" ]; then
  "$ROOT/scripts/css-scenario-test-report.sh" --stack "$STACK" --run-id "$RUN_ID" --profile "$PROFILE" --node-names "$NODE_NAMES" --writer-node "$WRITER_NODE" --timeout "$TIMEOUT" --stack-file "$STACK_FILE" --out-dir "$OUT_DIR"
fi
