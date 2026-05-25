#!/bin/sh
set -eu

RUN_ID=${CSS_TEST_RUN_ID:-manual}
SCENARIO=${CSS_TEST_SCENARIO:-unknown}
VOLUME=${CSS_TEST_VOLUME:-unknown}
MODE=${CSS_TEST_MODE:-unknown}
WRITE=${CSS_TEST_WRITE:-unknown}
ENGINE=${CSS_TEST_ENGINE:-unknown}
CRYPT=${CSS_TEST_CRYPT:-unknown}
BACKUP=${CSS_TEST_BACKUP:-none}
EXPECT_SHARED=${CSS_TEST_EXPECT_SHARED:-false}
EXPECT_NODES=${CSS_TEST_EXPECT_NODES:-}
SETTLE_SECONDS=${CSS_TEST_SETTLE_SECONDS:-20}
NODE_NAME=${NODE_NAME:-$(hostname)}
SERVICE_NAME=${SERVICE_NAME:-unknown}
TASK_SLOT=${TASK_SLOT:-0}

BASE=/data/css-scenario-test
RUN_DIR="$BASE/$RUN_ID/$SCENARIO"
WRITER_DIR="$RUN_DIR/writers"
REPORT_DIR="$RUN_DIR/reports"
NODE_FILE="$WRITER_DIR/$NODE_NAME.txt"
REPORT_FILE="$REPORT_DIR/$NODE_NAME.result"

mkdir -p "$WRITER_DIR" "$REPORT_DIR"

cat > "$NODE_FILE" <<EOF
run_id=$RUN_ID
scenario=$SCENARIO
node=$NODE_NAME
service=$SERVICE_NAME
task_slot=$TASK_SLOT
volume=$VOLUME
mode=$MODE
write=$WRITE
engine=$ENGINE
crypt=$CRYPT
backup=$BACKUP
created_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

sync "$NODE_FILE" 2>/dev/null || sync 2>/dev/null || true

if [ "$SETTLE_SECONDS" -gt 0 ] 2>/dev/null; then
  sleep "$SETTLE_SECONDS"
fi

if grep -q "scenario=$SCENARIO" "$NODE_FILE" && grep -q "node=$NODE_NAME" "$NODE_FILE"; then
  own_read=ok
else
  own_read=fail
fi

writers_seen=$(find "$WRITER_DIR" -type f -name '*.txt' -exec basename {} .txt \; 2>/dev/null | sort | tr '\n' ',' | sed 's/,$//')
writer_count=$(find "$WRITER_DIR" -type f -name '*.txt' 2>/dev/null | wc -l | tr -d ' ')
expected_min=1
if [ "$EXPECT_SHARED" = "true" ] && [ -n "$EXPECT_NODES" ]; then
  expected_min=$EXPECT_NODES
fi

status=PASS
notes=ok
if [ "$own_read" != "ok" ]; then
  status=FAIL
  notes=own_marker_read_failed
elif [ "$writer_count" -lt "$expected_min" ] 2>/dev/null; then
  status=FAIL
  notes=writers_seen_below_expected
fi

cat > "$REPORT_FILE" <<EOF
run_id=$RUN_ID
scenario=$SCENARIO
node=$NODE_NAME
service=$SERVICE_NAME
task_slot=$TASK_SLOT
volume=$VOLUME
opts=cs.mode:$MODE,cs.write:$WRITE,cs.engine:$ENGINE,cs.crypt:$CRYPT,cs.backup:$BACKUP
operations=mkdir,write_marker,sync,read_marker,list_writers
expected_min_writers=$expected_min
actual_writer_count=$writer_count
actual_writers_seen=$writers_seen
own_read=$own_read
status=$status
notes=$notes
completed_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

echo "CSS_SCENARIO_RESULT run_id=$RUN_ID scenario=$SCENARIO node=$NODE_NAME service=$SERVICE_NAME volume=$VOLUME mode=$MODE write=$WRITE engine=$ENGINE crypt=$CRYPT backup=$BACKUP operations=mkdir,write_marker,sync,read_marker,list_writers expected_min_writers=$expected_min actual_writer_count=$writer_count actual_writers_seen=${writers_seen:-none} own_read=$own_read status=$status notes=$notes"
