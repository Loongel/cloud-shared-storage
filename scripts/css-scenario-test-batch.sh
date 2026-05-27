#!/bin/sh
set -eu

STACK=${STACK:-css_scenario}
RUN_ID=${CSS_TEST_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}
PROFILE=${CSS_TEST_PROFILE:-full}
MAX_TASKS_PER_DEPLOY=${CSS_TEST_MAX_TASKS_PER_DEPLOY:-24}
TIMEOUT=${CSS_TEST_TIMEOUT:-240}
VERIFY_TIMEOUT=${CSS_TEST_VERIFY_TIMEOUT:-60}
FLUSH_SETTLE_SECONDS=${CSS_TEST_FLUSH_SETTLE_SECONDS:-10}
LABEL_ARGS=
CLEAN=0
CLEAR_LABELS=0
ALLOW_UNSTABLE_SWARM=0
ALLOW_LARGE_DEPLOY=0
EXTRA_DEPLOY_ARGS=
TMP_ROOT=

usage() {
  cat <<'EOF'
Usage: scripts/css-scenario-test-batch.sh [options]

Run the formal CSS scenario matrix in small sequential Stack batches. This is
the preferred entrypoint for core/full all-node validation because it avoids
creating too many Swarm global tasks and overlay endpoints at once.

Options:
  --stack NAME              Stack name, default css_scenario.
  --run-id ID               Test run id, default UTC timestamp.
  --profile PROFILE         full, core, smoke, backup-only, or shared-multi-only.
  --timeout SECONDS         Per-batch report wait timeout, default 240.
  --verify-timeout N        Workload verify timeout, default 60.
  --flush-settle-seconds N  Workload settle seconds, default 10.
  --current-node            Test only this node.
  --all-ready-nodes         Test every Ready node.
  --node NODE               Test a specific node; repeatable.
  --clean                   Clean the previous test stack before each batch.
  --clear-labels            Clear css.test.* labels after each batch.
  --max-tasks-per-deploy N  Max scenario-node tasks per batch, default 24.
  --allow-unstable-swarm    Pass through only for diagnostics.
  --allow-large-deploy      Disable batch-size guard inside deploy script.
  -h, --help                Show help.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --stack) shift; STACK=$1 ;;
    --run-id) shift; RUN_ID=$1 ;;
    --profile) shift; PROFILE=$1 ;;
    --timeout) shift; TIMEOUT=$1 ;;
    --verify-timeout) shift; VERIFY_TIMEOUT=$1 ;;
    --settle-seconds) shift; FLUSH_SETTLE_SECONDS=$1 ;;
    --flush-settle-seconds) shift; FLUSH_SETTLE_SECONDS=$1 ;;
    --current-node) LABEL_ARGS="$LABEL_ARGS --current-node" ;;
    --all-ready-nodes) LABEL_ARGS="$LABEL_ARGS --all-ready-nodes" ;;
    --node) shift; LABEL_ARGS="$LABEL_ARGS --node $1" ;;
    --clean) CLEAN=1 ;;
    --clear-labels) CLEAR_LABELS=1 ;;
    --max-tasks-per-deploy) shift; MAX_TASKS_PER_DEPLOY=$1 ;;
    --allow-unstable-swarm) ALLOW_UNSTABLE_SWARM=1 ;;
    --allow-large-deploy) ALLOW_LARGE_DEPLOY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
cd "$ROOT"

docker_cmd() {
  if docker info >/dev/null 2>&1; then
    docker "$@"
  else
    sudo -n docker "$@"
  fi
}

include_row() {
  id=$1
  mode=$2
  write=$3
  engine=$4
  crypt=$5
  backup=$6
  case "$PROFILE" in
    full) return 0 ;;
    core) [ "$backup" = false ] ;;
    smoke)
      case "$id" in
        p_s_a_p_n|p_s_a_e_n|s_s_a_p_n|s_s_a_e_n) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    backup-only) [ "$backup" = true ] ;;
    shared-multi-only) [ "$mode" = shared ] && [ "$write" = multi ] ;;
    *) echo "invalid profile: $PROFILE" >&2; exit 2 ;;
  esac
}

selected_node_count() {
  case "$LABEL_ARGS" in
    *--current-node*) echo 1; return ;;
  esac
  if [ -n "$(printf '%s' "$LABEL_ARGS" | sed -n 's/.*--node .*/x/p')" ]; then
    printf '%s\n' "$LABEL_ARGS" | tr ' ' '\n' | awk '$1 == "--node" {n++} END {print n ? n : 1}'
    return
  fi
  docker_cmd node ls --format '{{.Status}}' | awk '$1 == "Ready" {n++} END {print n ? n : 1}'
}

write_profile_scenarios() {
  out=$1
  printf 'id\tmode\twrite\tengine\tcrypt\tbackup\tworkload\n' > "$out"
  awk 'NR > 1 {print}' deploy/scenario-test/scenarios.tsv | while IFS="$(printf '\t')" read -r id mode write engine crypt backup workload; do
    [ -n "$id" ] || continue
    if include_row "$id" "$mode" "$write" "$engine" "$crypt" "$backup"; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$mode" "$write" "$engine" "$crypt" "$backup" "$workload" >> "$out"
    fi
  done
}

write_batch_file() {
  src=$1
  out=$2
  start=$3
  count=$4
  printf 'id\tmode\twrite\tengine\tcrypt\tbackup\tworkload\n' > "$out"
  awk -v start="$start" -v count="$count" 'NR > 1 {i=NR-1; if (i >= start && i < start + count) print}' "$src" >> "$out"
}

aggregate_reports() {
  out_dir=$1
  mkdir -p "$out_dir"
  results="$out_dir/results.tsv"
  controls="$out_dir/controls.tsv"
  preflight="$out_dir/preflight.tsv"
  report="$out_dir/report.md"
  first_results=1
  first_controls=1
  first_preflight=1
  for dir in "$out_dir"/batch-*; do
    [ -d "$dir" ] || continue
    if [ -f "$dir/results.tsv" ]; then
      if [ "$first_results" = "1" ]; then
        cat "$dir/results.tsv" > "$results"
        first_results=0
      else
        awk 'NR > 1 {print}' "$dir/results.tsv" >> "$results"
      fi
    fi
    if [ -f "$dir/controls.tsv" ]; then
      if [ "$first_controls" = "1" ]; then
        cat "$dir/controls.tsv" > "$controls"
        first_controls=0
      else
        awk 'NR > 1 {print}' "$dir/controls.tsv" >> "$controls"
      fi
    fi
    if [ -f "$dir/preflight.tsv" ]; then
      if [ "$first_preflight" = "1" ]; then
        cat "$dir/preflight.tsv" > "$preflight"
        first_preflight=0
      else
        awk 'NR > 1 {print}' "$dir/preflight.tsv" >> "$preflight"
      fi
    fi
  done
  rows=$(awk 'NR > 1 {n++} END {print n+0}' "$results" 2>/dev/null || echo 0)
  pass=$(awk -F '\t' 'NR > 1 && $23 == "PASS" {n++} END {print n+0}' "$results" 2>/dev/null || echo 0)
  fail=$(awk -F '\t' 'NR > 1 && $23 == "FAIL" {n++} END {print n+0}' "$results" 2>/dev/null || echo 0)
  blocked=$(awk -F '\t' 'NR > 1 && $23 == "BLOCKED" {n++} END {print n+0}' "$results" 2>/dev/null || echo 0)
  control_fail=$(awk -F '\t' 'NR > 1 && $4 == "FAIL" {n++} END {print n+0}' "$controls" 2>/dev/null || echo 0)
  control_blocked=$(awk -F '\t' 'NR > 1 && $4 == "BLOCKED" {n++} END {print n+0}' "$controls" 2>/dev/null || echo 0)
  preflight_fail=$(awk -F '\t' 'NR > 1 && $3 == "FAIL" {n++} END {print n+0}' "$preflight" 2>/dev/null || echo 0)
  preflight_blocked=$(awk -F '\t' 'NR > 1 && $3 == "BLOCKED" {n++} END {print n+0}' "$preflight" 2>/dev/null || echo 0)
  {
    printf '# CSS Scenario Batch Report\n\n'
    printf '- run_id: `%s`\n' "$RUN_ID"
    printf '- profile: `%s`\n' "$PROFILE"
    printf '- rows: `%s`\n' "$rows"
    printf '- pass: `%s`\n' "$pass"
    printf '- fail: `%s`\n' "$fail"
    printf '- blocked: `%s`\n' "$blocked"
    printf '- control_fail: `%s`\n' "$control_fail"
    printf '- control_blocked: `%s`\n' "$control_blocked"
    printf '- preflight_fail: `%s`\n' "$preflight_fail"
    printf '- preflight_blocked: `%s`\n\n' "$preflight_blocked"
    printf 'Batch reports are under `%s/batch-*`.\n' "$out_dir"
  } > "$report"
  echo "CSS_SCENARIO_BATCH_REPORT run_id=$RUN_ID profile=$PROFILE rows=$rows pass=$pass fail=$fail blocked=$blocked control_fail=$control_fail control_blocked=$control_blocked preflight_fail=$preflight_fail preflight_blocked=$preflight_blocked md=$report"
  [ "$fail" = "0" ] && [ "$blocked" = "0" ] && [ "$control_fail" = "0" ] && [ "$control_blocked" = "0" ] && [ "$preflight_fail" = "0" ] && [ "$preflight_blocked" = "0" ]
}

TMP_ROOT=$(mktemp -d /tmp/css-scenario-batch.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM

profile_file="$TMP_ROOT/scenarios.tsv"
write_profile_scenarios "$profile_file"
scenario_count=$(awk 'NR > 1 {n++} END {print n+0}' "$profile_file")
[ "$scenario_count" -gt 0 ] || { echo "no scenarios selected for profile=$PROFILE" >&2; exit 1; }
node_count=$(selected_node_count)
batch_size=$((MAX_TASKS_PER_DEPLOY / node_count))
[ "$batch_size" -ge 1 ] || batch_size=1

out_dir="reports/css-scenario-$RUN_ID"
mkdir -p "$out_dir"
echo "CSS_SCENARIO_BATCH_BEGIN run_id=$RUN_ID profile=$PROFILE scenarios=$scenario_count nodes=$node_count batch_size=$batch_size max_tasks=$MAX_TASKS_PER_DEPLOY"

start=1
batch=1
while [ "$start" -le "$scenario_count" ]; do
  batch_file="$TMP_ROOT/batch-$batch.tsv"
  write_batch_file "$profile_file" "$batch_file" "$start" "$batch_size"
  batch_run_id="${RUN_ID}-batch-${batch}"
  batch_out="$out_dir/batch-$batch"
  clean_arg=
  [ "$CLEAN" = "1" ] && clean_arg=--clean
  clear_arg=
  [ "$CLEAR_LABELS" = "1" ] && clear_arg=--clear-labels
  unstable_arg=
  [ "$ALLOW_UNSTABLE_SWARM" = "1" ] && unstable_arg=--allow-unstable-swarm
  large_arg=
  [ "$ALLOW_LARGE_DEPLOY" = "1" ] && large_arg=--allow-large-deploy
  echo "CSS_SCENARIO_BATCH_DEPLOY batch=$batch start=$start scenarios=$(awk 'NR > 1 {printf \"%s%s\", sep, $1; sep=\",\"}' "$batch_file")"
  # shellcheck disable=SC2086
  CSS_TEST_RUN_ID="$batch_run_id" OUT_DIR="$batch_out" sh scripts/css-scenario-test-deploy.sh \
    --stack "$STACK" \
    --profile "$PROFILE" \
    --timeout "$TIMEOUT" \
    --verify-timeout "$VERIFY_TIMEOUT" \
    --flush-settle-seconds "$FLUSH_SETTLE_SECONDS" \
    --max-tasks-per-deploy "$MAX_TASKS_PER_DEPLOY" \
    --scenarios-file "$batch_file" \
    $LABEL_ARGS $clean_arg $clear_arg $unstable_arg $large_arg $EXTRA_DEPLOY_ARGS
  start=$((start + batch_size))
  batch=$((batch + 1))
done

aggregate_reports "$out_dir"
