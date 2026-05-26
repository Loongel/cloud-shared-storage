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
LABEL_MODE=current
CLEAN=0
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
  if docker info >/dev/null 2>&1; then
    docker "$@"
  else
    sudo -n docker "$@"
  fi
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
    docker_cmd node update --label-rm "$label" "$node" >/dev/null 2>&1 || true
  done
}

clear_all_test_labels() {
  for node in $(docker_cmd node ls -q); do
    clear_node_labels "$node"
  done
}

scenario_volume_names() {
  awk 'NR > 1 {print $1}' "$ROOT/deploy/scenario-test/scenarios.tsv" | while read -r sid; do
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
  cleanup_remote_node_state
}

cleanup_remote_node_state() {
  cleanup_stack="${STACK}_cleanup"
  cleanup_tmp=$(mktemp -d /tmp/css-scenario-cleanup.XXXXXX)
  cat > "$cleanup_tmp/stack.yml" <<EOF
version: "3.8"
services:
  cleanup:
    image: docker:27-cli
    entrypoint:
      - /bin/sh
      - -c
    command:
      - |
        docker run --rm --privileged --pid host --network host -v /:/host alpine:3.20 chroot /host /bin/sh -c 'set -eu; for d in /mnt/cs_storage/vols/${STACK}_css_* /mnt/cs_storage/vols/css_preflight_*; do test -e "\$\$d" || continue; for sub in mount remote cipher gluster litefs-mount; do umount -lf "\$\$d/\$\$sub" >/dev/null 2>&1 || true; done; rm -rf "\$\$d"; done'
    volumes:
      - type: bind
        source: /var/run/docker.sock
        target: /var/run/docker.sock
    deploy:
      mode: global
      restart_policy:
        condition: none
EOF
  docker_cmd stack rm "$cleanup_stack" >/dev/null 2>&1 || true
  docker_cmd stack deploy -c "$cleanup_tmp/stack.yml" "$cleanup_stack" >/dev/null || {
    rm -rf "$cleanup_tmp"
    return 0
  }
  service="${cleanup_stack}_cleanup"
  for _ in $(seq 1 120); do
    states=$(docker_cmd service ps "$service" --format '{{.CurrentState}}' 2>/dev/null || true)
    active=$(printf '%s\n' "$states" | awk '$1 ~ /^(New|Pending|Assigned|Accepted|Preparing|Ready|Starting|Running)$/ {n++} END {print n+0}')
    [ "$active" = "0" ] && break
    sleep 1
  done
  docker_cmd stack rm "$cleanup_stack" >/dev/null 2>&1 || true
  rm -rf "$cleanup_tmp"
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

  if note=$(tool_version litefs version -version --version); then
    printf 'runtime-tool\tlitefs\tPASS\t%s\n' "$note" >> "$pf"
  else
    printf 'runtime-tool\tlitefs\tFAIL\tmissing_from_host_path\n' >> "$pf"
  fi
  if note=$(tool_version kopia --version version); then
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
    if docker_cmd node update "$@" "$node" >/dev/null; then
      return 0
    fi
    i=$((i + 1))
    [ "$i" -lt 6 ] || return 1
    sleep "$i"
  done
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

case "$LABEL_MODE" in
  current)
    current=$(docker_cmd info --format '{{.Swarm.NodeID}}')
    [ -n "$current" ] || { echo "this Docker engine is not a Swarm node" >&2; exit 1; }
    NODES=$current
    ;;
  all)
    NODES=$(docker_cmd node ls --format '{{.ID}}\t{{.Status}}' | awk -F '\t' '$2 == "Ready" {print $1}' | tr '\n' ' ')
    ;;
  explicit) ;;
esac

[ -n "$NODES" ] || { echo "no nodes selected for css scenario test" >&2; exit 1; }

clear_all_test_labels

for node in $NODES; do
  label_node "$node"
done

NODE_NAMES=$(
  for node in $NODES; do
    docker_cmd node inspect --format '{{.Description.Hostname}}' "$node"
  done | sort | tr '\n' ',' | sed 's/,$//'
)
WRITER_NODE=$(printf '%s\n' "$NODE_NAMES" | tr ',' '\n' | sed '/^$/d' | sort | sed -n '1p')
EXPECT_NODES=$(printf '%s\n' "$NODE_NAMES" | tr ',' '\n' | sed '/^$/d' | wc -l | tr -d ' ')

if [ -z "$STACK_FILE" ]; then
  RENDERED_STACK=$(mktemp /tmp/css-scenario-stack.XXXXXX.yml)
  sh "$ROOT/deploy/scenario-test/render-stack.sh" --profile "$PROFILE" --workload-file "$ROOT/deploy/scenario-test/workload.sh" --out "$RENDERED_STACK"
  STACK_FILE=$RENDERED_STACK
fi

OUT_DIR="reports/css-scenario-$RUN_ID"

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
docker_cmd stack deploy -c "$STACK_FILE" "$STACK"

if [ "$REPORT" = "1" ]; then
  "$ROOT/scripts/css-scenario-test-report.sh" --stack "$STACK" --run-id "$RUN_ID" --profile "$PROFILE" --node-names "$NODE_NAMES" --writer-node "$WRITER_NODE" --timeout "$TIMEOUT" --stack-file "$STACK_FILE" --out-dir "$OUT_DIR"
fi
