#!/bin/sh
set -eu

PROFILE=${PROFILE:-full}
OUT=${OUT:-}
SCENARIOS=${SCENARIOS:-}
WORKLOAD_FILE=${WORKLOAD_FILE:-}

usage() {
  cat <<'EOF'
Usage: deploy/scenario-test/render-stack.sh [options]

Render the CSS scenario-test Docker Stack from scenarios.tsv.

Options:
  --profile full|core|smoke|backup-only|shared-multi-only
  --scenarios FILE
  --workload-file FILE
  --out FILE
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile) shift; PROFILE=$1 ;;
    --scenarios) shift; SCENARIOS=$1 ;;
    --workload-file) shift; WORKLOAD_FILE=$1 ;;
    --out) shift; OUT=$1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
if [ -z "$SCENARIOS" ]; then
  SCENARIOS="$ROOT/deploy/scenario-test/scenarios.tsv"
fi
if [ -z "$WORKLOAD_FILE" ]; then
  WORKLOAD_FILE="../scenario-test/workload.sh"
fi

include_row() {
  id=$1
  mode=$2
  write=$3
  engine=$4
  crypt=$5
  backup=$6
  case "$PROFILE" in
    full) return 0 ;;
    core) [ "$backup" = none ] && return 0 || return 1 ;;
    smoke)
      case "$id" in
        p_s_a_p_n|p_s_a_e_n|s_s_a_p_n|s_s_a_e_n) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    backup-only) [ "$backup" = auto ] && return 0 || return 1 ;;
    shared-multi-only) [ "$mode" = shared ] && [ "$write" = multi ] && return 0 || return 1 ;;
    *)
      echo "invalid profile: $PROFILE" >&2
      exit 2
      ;;
  esac
}

render() {
  cat <<EOF
version: "3.8"

configs:
  css_scenario_workload:
    file: $WORKLOAD_FILE

services:
EOF

  awk 'NR > 1 {print}' "$SCENARIOS" | while IFS="$(printf '\t')" read -r id mode write engine crypt backup workload; do
    [ -n "$id" ] || continue
    if ! include_row "$id" "$mode" "$write" "$engine" "$crypt" "$backup"; then
      continue
    fi
    case "$workload" in
      shared-multi-sqlite|shared-multi-auto) image='${CSS_TEST_SQLITE_IMAGE:-busybox:1.36}' ;;
      *) image='${CSS_TEST_WORKLOAD_IMAGE:-busybox:1.36}' ;;
    esac
    cat <<EOF
  $id:
    image: "$image"
    command: ["/bin/sh", "/usr/local/bin/css-scenario-workload"]
    configs:
      - source: css_scenario_workload
        target: /usr/local/bin/css-scenario-workload
        mode: 0555
    environment:
      CSS_TEST_RUN_ID: "\${CSS_TEST_RUN_ID}"
      CSS_TEST_PROFILE: "\${CSS_TEST_PROFILE:-$PROFILE}"
      CSS_TEST_NODE_NAMES: "\${CSS_TEST_NODE_NAMES}"
      CSS_TEST_EXPECT_NODES: "\${CSS_TEST_EXPECT_NODES}"
      CSS_TEST_WRITER_NODE: "\${CSS_TEST_WRITER_NODE}"
      CSS_TEST_VERIFY_TIMEOUT: "\${CSS_TEST_VERIFY_TIMEOUT:-60}"
      CSS_TEST_FLUSH_SETTLE_SECONDS: "\${CSS_TEST_FLUSH_SETTLE_SECONDS:-10}"
      CSS_TEST_SCENARIO: "$id"
      CSS_TEST_VOLUME: "css_$id"
      CSS_TEST_MODE: "$mode"
      CSS_TEST_WRITE: "$write"
      CSS_TEST_ENGINE: "$engine"
      CSS_TEST_CRYPT: "$crypt"
      CSS_TEST_BACKUP: "$backup"
      CSS_TEST_WORKLOAD: "$workload"
      NODE_NAME: "{{.Node.Hostname}}"
      SERVICE_NAME: "{{.Service.Name}}"
      TASK_SLOT: "{{.Task.Slot}}"
    deploy:
      mode: global
      labels:
        css.test.scenario: "$id"
        css.test.mode: "$mode"
        css.test.write: "$write"
        css.test.engine: "$engine"
        css.test.crypt: "$crypt"
        css.test.backup: "$backup"
        css.test.workload: "$workload"
      placement:
        constraints:
          - node.labels.css.test.enabled == true
      restart_policy:
        condition: none
    volumes:
      - css_$id:/data

EOF
  done

  cat <<'EOF'
volumes:
EOF

  awk 'NR > 1 {print}' "$SCENARIOS" | while IFS="$(printf '\t')" read -r id mode write engine crypt backup workload; do
    [ -n "$id" ] || continue
    if ! include_row "$id" "$mode" "$write" "$engine" "$crypt" "$backup"; then
      continue
    fi
    cat <<EOF
  css_$id:
    driver: css
    driver_opts:
      cs.mode: "$mode"
      cs.write: "$write"
      cs.engine: "$engine"
      cs.crypt: "$crypt"
      cs.backup: "$backup"
      flush: "true"

EOF
  done
}

if [ -n "$OUT" ]; then
  render > "$OUT"
else
  render
fi
