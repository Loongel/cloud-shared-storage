#!/bin/sh
set -eu

RUN_ID=${CSS_TEST_RUN_ID:-manual}
SCENARIO=${CSS_TEST_SCENARIO:-unknown}
VOLUME=${CSS_TEST_VOLUME:-unknown}
MODE=${CSS_TEST_MODE:-unknown}
WRITE=${CSS_TEST_WRITE:-unknown}
ENGINE=${CSS_TEST_ENGINE:-unknown}
CRYPT=${CSS_TEST_CRYPT:-unknown}
BACKUP=${CSS_TEST_BACKUP:-false}
WORKLOAD=${CSS_TEST_WORKLOAD:-private-file}
NODE_NAMES=${CSS_TEST_NODE_NAMES:-}
EXPECT_NODES=${CSS_TEST_EXPECT_NODES:-}
WRITER_NODE=${CSS_TEST_WRITER_NODE:-}
VERIFY_TIMEOUT=${CSS_TEST_VERIFY_TIMEOUT:-60}
FLUSH_SETTLE_SECONDS=${CSS_TEST_FLUSH_SETTLE_SECONDS:-10}
NODE_NAME=${NODE_NAME:-$(hostname)}
SERVICE_NAME=${SERVICE_NAME:-unknown}
TASK_SLOT=${TASK_SLOT:-0}

ROOT=/data/css-scenario-test
RUN_DIR="$ROOT/$RUN_ID/$SCENARIO"
WRITER_DIR="$RUN_DIR/writers"
CHECKSUM_DIR="$RUN_DIR/checksums"
READER_DIR="$RUN_DIR/readers"
SQLITE_DIR="$RUN_DIR/sqlite"
REPORT_DIR="$RUN_DIR/reports"

if [ ! -d /data ]; then
  echo "CSS_SCENARIO_RESULT run_id=$RUN_ID profile=${CSS_TEST_PROFILE:-unknown} scenario=$SCENARIO node=$NODE_NAME service=$SERVICE_NAME volume=$VOLUME mode=$MODE write=$WRITE engine=$ENGINE crypt=$CRYPT backup=$BACKUP workload=$WORKLOAD role=mount-check writer_node=${WRITER_NODE:-none} node_names=${NODE_NAMES:-none} expected_nodes=${EXPECT_NODES:-0} expected_visible=none actual_visible=none missing=none unexpected=none operations=mount_check own_sha=none sqlite_integrity=na sqlite_rows=na sqlite_missing=na status=FAIL notes=mount_target_missing"
  exit 0
fi

if [ "$WORKLOAD" = "shared-multi-sqlite" ]; then
  if ! test -d /data; then
    echo "CSS_SCENARIO_RESULT run_id=$RUN_ID profile=${CSS_TEST_PROFILE:-unknown} scenario=$SCENARIO node=$NODE_NAME service=$SERVICE_NAME volume=$VOLUME mode=$MODE write=$WRITE engine=$ENGINE crypt=$CRYPT backup=$BACKUP workload=$WORKLOAD role=mount-check writer_node=${WRITER_NODE:-none} node_names=${NODE_NAMES:-none} expected_nodes=${EXPECT_NODES:-0} expected_visible=none actual_visible=none missing=none unexpected=none operations=mount_check own_sha=none sqlite_integrity=na sqlite_rows=na sqlite_missing=na status=FAIL notes=mount_target_missing"
    exit 0
  fi
elif ! mkdir -p "$WRITER_DIR" "$CHECKSUM_DIR" "$READER_DIR" "$REPORT_DIR"; then
  echo "CSS_SCENARIO_RESULT run_id=$RUN_ID profile=${CSS_TEST_PROFILE:-unknown} scenario=$SCENARIO node=$NODE_NAME service=$SERVICE_NAME volume=$VOLUME mode=$MODE write=$WRITE engine=$ENGINE crypt=$CRYPT backup=$BACKUP workload=$WORKLOAD role=mount-check writer_node=${WRITER_NODE:-none} node_names=${NODE_NAMES:-none} expected_nodes=${EXPECT_NODES:-0} expected_visible=none actual_visible=none missing=none unexpected=none operations=mkdir own_sha=none sqlite_integrity=na sqlite_rows=na sqlite_missing=na status=FAIL notes=mount_write_unavailable"
  exit 0
fi

csv_count() {
  v=$1
  [ -n "$v" ] || { echo 0; return; }
  printf '%s\n' "$v" | tr ',' '\n' | sed '/^$/d' | wc -l | tr -d ' '
}

csv_first() {
  printf '%s\n' "$1" | tr ',' '\n' | sed '/^$/d' | sort | sed -n '1p'
}

csv_contains() {
  needle=$1
  haystack=$2
  printf '%s\n' "$haystack" | tr ',' '\n' | awk -v n="$needle" '$0 == n {found=1} END {exit found ? 0 : 1}'
}

join_csv_files() {
  dir=$1
  find "$dir" -type f -name '*.txt' -exec basename {} .txt \; 2>/dev/null | sort | tr '\n' ',' | sed 's/,$//'
}

missing_from_csv() {
  expected=$1
  actual=$2
  out=
  for n in $(printf '%s\n' "$expected" | tr ',' ' '); do
    [ -n "$n" ] || continue
    if ! csv_contains "$n" "$actual"; then
      out="${out}${out:+,}$n"
    fi
  done
  printf '%s' "$out"
}

unexpected_from_csv() {
  actual=$1
  expected=$2
  out=
  for n in $(printf '%s\n' "$actual" | tr ',' ' '); do
    [ -n "$n" ] || continue
    if ! csv_contains "$n" "$expected"; then
      out="${out}${out:+,}$n"
    fi
  done
  printf '%s' "$out"
}

sha_file() {
  sha256sum "$1" | awk '{print $1}'
}

marker_role() {
  case "$WORKLOAD" in
    private-file) echo private-writer ;;
    shared-single-file) echo shared-writer ;;
    shared-multi-sqlite) echo sqlite-writer ;;
    shared-multi-auto) echo auto-writer ;;
    *) echo multi-writer ;;
  esac
}

write_marker() {
  node=$1
  role=$2
  file="$WRITER_DIR/$node.txt"
  {
    printf 'run_id=%s\n' "$RUN_ID"
    printf 'scenario=%s\n' "$SCENARIO"
    printf 'node=%s\n' "$node"
    printf 'role=%s\n' "$role"
    printf 'volume=%s\n' "$VOLUME"
    printf 'mode=%s\n' "$MODE"
    printf 'write=%s\n' "$WRITE"
    printf 'engine=%s\n' "$ENGINE"
    printf 'crypt=%s\n' "$CRYPT"
    printf 'backup=%s\n' "$BACKUP"
    printf 'workload=%s\n' "$WORKLOAD"
  } > "$file"
  sha_file "$file" > "$CHECKSUM_DIR/$node.sha256"
}

need_sqlite=0
case "$WORKLOAD" in
  shared-multi-sqlite|shared-multi-auto) need_sqlite=1 ;;
esac

status=PASS
notes=ok
sqlite_integrity=na
sqlite_rows=na
sqlite_missing=na
operations=mkdir

if [ -z "$NODE_NAMES" ]; then
  NODE_NAMES=$NODE_NAME
fi
if [ -z "$EXPECT_NODES" ]; then
  EXPECT_NODES=$(csv_count "$NODE_NAMES")
fi
if [ -z "$WRITER_NODE" ]; then
  WRITER_NODE=$(csv_first "$NODE_NAMES")
fi

expected_visible=$NODE_NAME
should_write=1
role=$(marker_role)

case "$WORKLOAD" in
  private-file)
    expected_visible=$NODE_NAME
    should_write=1
    ;;
  shared-single-file)
    expected_visible=$WRITER_NODE
    if [ "$NODE_NAME" = "$WRITER_NODE" ]; then should_write=1; else should_write=0; fi
    ;;
  shared-multi-file|shared-multi-auto)
    expected_visible=$NODE_NAMES
    should_write=1
    ;;
  shared-multi-sqlite)
    expected_visible=$NODE_NAMES
    should_write=0
    ;;
  *)
    status=BLOCKED
    notes=unknown_workload
    should_write=0
    ;;
esac

if [ "$should_write" = "1" ]; then
  write_marker "$NODE_NAME" "$role"
  operations="${operations},write_marker"
fi

if [ "$need_sqlite" = "1" ]; then
  operations="${operations},sqlite_write"
  if ! command -v sqlite3 >/dev/null 2>&1; then
    status=BLOCKED
    notes=missing_sqlite3_in_workload_image
  else
    if [ "$WORKLOAD" = "shared-multi-sqlite" ] || [ "$WORKLOAD" = "shared-multi-auto" ]; then
      db="/data/main.db"
    else
      mkdir -p "$SQLITE_DIR"
      db="$SQLITE_DIR/main.db"
    fi
    payload="$RUN_ID:$SCENARIO:$NODE_NAME:$MODE:$WRITE:$ENGINE:$CRYPT:$BACKUP"
    if ! sqlite3 "$db" "PRAGMA busy_timeout=5000; CREATE TABLE IF NOT EXISTS css_rows(node TEXT PRIMARY KEY, scenario TEXT, payload TEXT); INSERT OR REPLACE INTO css_rows(node, scenario, payload) VALUES ('$NODE_NAME', '$SCENARIO', '$payload');"; then
      status=FAIL
      notes=sqlite_write_failed
    fi
  fi
fi

sync 2>/dev/null || true
if [ "$FLUSH_SETTLE_SECONDS" -gt 0 ] 2>/dev/null; then
  sleep "$FLUSH_SETTLE_SECONDS"
fi

actual_visible=none
missing=none
unexpected=none
if [ "$WORKLOAD" != "shared-multi-sqlite" ]; then
  deadline=$(( $(date +%s) + VERIFY_TIMEOUT ))
  actual_visible=
  missing=
  unexpected=
  while :; do
    actual_visible=$(join_csv_files "$WRITER_DIR")
    missing=$(missing_from_csv "$expected_visible" "$actual_visible")
    unexpected=$(unexpected_from_csv "$actual_visible" "$expected_visible")
    [ -z "$missing" ] && [ -z "$unexpected" ] && break
    [ "$(date +%s)" -ge "$deadline" ] && break
    sleep 2
  done
  operations="${operations},poll_markers"

  if [ "$status" = "PASS" ]; then
    if [ -n "$missing" ]; then
      status=FAIL
      notes=missing_expected_markers
    elif [ -n "$unexpected" ]; then
      status=FAIL
      notes=unexpected_markers_visible
    fi
  fi
fi

if [ "$need_sqlite" = "1" ] && [ "$status" != "BLOCKED" ] && command -v sqlite3 >/dev/null 2>&1; then
  if [ "$WORKLOAD" = "shared-multi-sqlite" ] || [ "$WORKLOAD" = "shared-multi-auto" ]; then
    db="/data/main.db"
  else
    db="$SQLITE_DIR/main.db"
  fi
  deadline=$(( $(date +%s) + VERIFY_TIMEOUT ))
  while :; do
    sqlite_integrity=$(sqlite3 "$db" "PRAGMA integrity_check;" 2>/dev/null || echo error)
    sqlite_rows=$(sqlite3 "$db" "SELECT COUNT(*) FROM css_rows WHERE scenario='$SCENARIO';" 2>/dev/null || echo error)
    if [ "$sqlite_integrity" = ok ] && [ "$sqlite_rows" = "$EXPECT_NODES" ]; then
      break
    fi
    [ "$(date +%s)" -ge "$deadline" ] && break
    sleep 2
  done
  missing_sql=
  for n in $(printf '%s\n' "$NODE_NAMES" | tr ',' ' '); do
    found=$(sqlite3 "$db" "SELECT COUNT(*) FROM css_rows WHERE scenario='$SCENARIO' AND node='$n';" 2>/dev/null || echo 0)
    [ "$found" = 1 ] || missing_sql="${missing_sql}${missing_sql:+,}$n"
  done
  sqlite_missing=${missing_sql:-none}
  operations="${operations},sqlite_verify"
  if [ "$status" = "PASS" ]; then
    if [ "$sqlite_integrity" != ok ]; then
      status=FAIL
      notes=sqlite_integrity_failed
    elif [ "$sqlite_rows" != "$EXPECT_NODES" ]; then
      status=FAIL
      notes=sqlite_row_count_mismatch
    elif [ "$sqlite_missing" != none ]; then
      status=FAIL
      notes=sqlite_missing_rows
    fi
  fi
fi

if [ "$WORKLOAD" != "shared-multi-sqlite" ]; then
  reader_file="$READER_DIR/$NODE_NAME.txt"
  {
    printf 'node=%s\n' "$NODE_NAME"
    printf 'expected_visible=%s\n' "$expected_visible"
    printf 'actual_visible=%s\n' "$actual_visible"
    printf 'missing=%s\n' "${missing:-none}"
    printf 'unexpected=%s\n' "${unexpected:-none}"
    printf 'sqlite_integrity=%s\n' "$sqlite_integrity"
    printf 'sqlite_rows=%s\n' "$sqlite_rows"
    printf 'status=%s\n' "$status"
    printf 'notes=%s\n' "$notes"
  } > "$reader_file"
fi

own_sha=none
if [ -f "$CHECKSUM_DIR/$NODE_NAME.sha256" ]; then
  own_sha=$(sed -n '1p' "$CHECKSUM_DIR/$NODE_NAME.sha256")
fi

echo "CSS_SCENARIO_RESULT run_id=$RUN_ID profile=${CSS_TEST_PROFILE:-unknown} scenario=$SCENARIO node=$NODE_NAME service=$SERVICE_NAME volume=$VOLUME mode=$MODE write=$WRITE engine=$ENGINE crypt=$CRYPT backup=$BACKUP workload=$WORKLOAD role=$role writer_node=$WRITER_NODE node_names=$NODE_NAMES expected_nodes=$EXPECT_NODES expected_visible=${expected_visible:-none} actual_visible=${actual_visible:-none} missing=${missing:-none} unexpected=${unexpected:-none} operations=$operations own_sha=$own_sha sqlite_integrity=$sqlite_integrity sqlite_rows=$sqlite_rows sqlite_missing=$sqlite_missing status=$status notes=$notes"
