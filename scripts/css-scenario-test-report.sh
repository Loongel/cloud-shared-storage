#!/bin/sh
set -eu

STACK=${STACK:-css_scenario}
RUN_ID=${CSS_TEST_RUN_ID:-}
TIMEOUT=${CSS_TEST_TIMEOUT:-240}
OUT_DIR=${OUT_DIR:-}
CHECK_BACKEND=1
SERVER_ENV=${SERVER_ENV:-/etc/cs-storage/server.env}

usage() {
  cat <<'EOF'
Usage: scripts/css-scenario-test-report.sh [options]

Collect CSS scenario stack results and write a TSV plus Markdown report.

Options:
  --stack NAME          Stack name, default css_scenario.
  --run-id ID           Run id to collect. Defaults to latest stack logs.
  --timeout SECONDS     Wait timeout for workload tasks, default 240.
  --out-dir DIR         Report directory, default reports/css-scenario-<run-id>.
  --no-backend-check    Skip direct WebDAV backend checks.
  --server-env FILE     Server env used for backend credentials, default /etc/cs-storage/server.env.
  -h, --help            Show help.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --stack) shift; STACK=$1 ;;
    --run-id) shift; RUN_ID=$1 ;;
    --timeout) shift; TIMEOUT=$1 ;;
    --out-dir) shift; OUT_DIR=$1 ;;
    --no-backend-check) CHECK_BACKEND=0 ;;
    --server-env) shift; SERVER_ENV=$1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -d "$SCRIPT_DIR/../deploy" ]; then
  ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
else
  ROOT=$(pwd)
fi
cd "$ROOT"

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
  [ -f "$file" ] || return 1
  awk -F= -v k="$key" '$1 == k {sub(/^[^=]*=/, ""); print; found=1; exit} END {exit found ? 0 : 1}' "$file"
}

get_kv() {
  line=$1
  key=$2
  printf '%s\n' "$line" | tr ' ' '\n' | awk -F= -v k="$key" '$1 == k {sub(/^[^=]*=/, ""); print; found=1; exit} END {exit found ? 0 : 1}'
}

join_url() {
  base=$1
  rel=$2
  printf '%s/%s' "$(printf '%s' "$base" | sed 's:/*$::')" "$(printf '%s' "$rel" | sed 's:^/*::')"
}

backend_ready=0
BACKEND_URL=
BACKEND_AUTH_HEADER=
BACKEND_USER=
BACKEND_PASSWORD=

load_backend_config() {
  [ "$CHECK_BACKEND" = "1" ] || return
  [ -f "$SERVER_ENV" ] || return
  BACKEND_URL=$(read_env_value "$SERVER_ENV" CS_BACKEND_URL 2>/dev/null || true)
  auth_file=$(read_env_value "$SERVER_ENV" CS_BACKEND_AUTH_HEADER_FILE 2>/dev/null || true)
  user_file=$(read_env_value "$SERVER_ENV" CS_BACKEND_USER_FILE 2>/dev/null || true)
  pass_file=$(read_env_value "$SERVER_ENV" CS_BACKEND_PASSWORD_FILE 2>/dev/null || true)
  [ -n "$BACKEND_URL" ] || return
  if [ -n "$auth_file" ] && [ -r "$auth_file" ]; then
    BACKEND_AUTH_HEADER=$(sed -n '1p' "$auth_file")
    backend_ready=1
    return
  fi
  if [ -n "$user_file" ] && [ -n "$pass_file" ] && [ -r "$user_file" ] && [ -r "$pass_file" ]; then
    BACKEND_USER=$(sed -n '1p' "$user_file")
    BACKEND_PASSWORD=$(sed -n '1p' "$pass_file")
    backend_ready=1
  fi
}

curl_backend() {
  rel=$1
  url=$(join_url "$BACKEND_URL" "$rel")
  if [ -n "$BACKEND_AUTH_HEADER" ]; then
    curl -fsS -H "Authorization: $BACKEND_AUTH_HEADER" "$url"
  else
    curl -fsS -u "$BACKEND_USER:$BACKEND_PASSWORD" "$url"
  fi
}

backend_check() {
  scenario=$1
  node=$2
  crypt=$3
  if [ "$backend_ready" != "1" ]; then
    printf 'SKIP:backend_config_unavailable'
    return
  fi
  plain_rel="nodes/$node/css-scenario-test/$RUN_ID/$scenario/writers/$node.txt"
  if [ "$crypt" = "true" ]; then
    if curl_backend "$plain_rel" >/tmp/css-backend-plain.$$ 2>/dev/null; then
      rm -f /tmp/css-backend-plain.$$
      printf 'FAIL:plaintext_visible_on_backend'
      return
    fi
    rm -f /tmp/css-backend-plain.$$
    if curl_backend "nodes/$node/cipher/gocryptfs.conf" >/dev/null 2>&1; then
      printf 'PASS:encrypted_cipher_present_plaintext_absent'
    else
      printf 'FAIL:encrypted_cipher_missing'
    fi
    return
  fi
  if curl_backend "$plain_rel" >/tmp/css-backend-plain.$$ 2>/dev/null; then
    if grep -q "scenario=$scenario" /tmp/css-backend-plain.$$ && grep -q "node=$node" /tmp/css-backend-plain.$$; then
      rm -f /tmp/css-backend-plain.$$
      printf 'PASS:plaintext_marker_present'
    else
      rm -f /tmp/css-backend-plain.$$
      printf 'FAIL:plaintext_marker_content_mismatch'
    fi
  else
    rm -f /tmp/css-backend-plain.$$
    printf 'FAIL:plaintext_marker_missing'
  fi
}

wait_for_services() {
  start=$(date +%s)
  while :; do
    running=0
    for svc in $(docker_cmd stack services --format '{{.Name}}' "$STACK" 2>/dev/null || true); do
      states=$(docker_cmd service ps --no-trunc --format '{{.CurrentState}}' "$svc" 2>/dev/null || true)
      if printf '%s\n' "$states" | grep -Eq '^(New|Pending|Assigned|Accepted|Preparing|Ready|Starting|Running) '; then
        running=1
      fi
    done
    [ "$running" = "0" ] && break
    now=$(date +%s)
    if [ $((now - start)) -ge "$TIMEOUT" ]; then
      echo "timeout waiting for stack tasks; collecting partial results" >&2
      break
    fi
    sleep 3
  done
}

load_backend_config
wait_for_services

if [ -z "$RUN_ID" ]; then
  RUN_ID=$(docker_cmd service logs --raw "${STACK}_private_plain" 2>/dev/null | grep 'CSS_SCENARIO_RESULT' | tail -1 | tr ' ' '\n' | awk -F= '$1=="run_id"{print $2; exit}')
fi
[ -n "$RUN_ID" ] || { echo "missing --run-id and no scenario log results found" >&2; exit 1; }

if [ -z "$OUT_DIR" ]; then
  OUT_DIR="reports/css-scenario-$RUN_ID"
fi
mkdir -p "$OUT_DIR"
TSV="$OUT_DIR/results.tsv"
MD="$OUT_DIR/report.md"
LOGS="$OUT_DIR/service-logs.txt"
: > "$LOGS"

printf 'scenario\tnode\tservice\tvolume\tdriver_opts\toperations\texpected\tactual_volume_state\tactual_backend_state\tstatus\tnotes\n' > "$TSV"

for svc in $(docker_cmd stack services --format '{{.Name}}' "$STACK" 2>/dev/null | sort); do
  docker_cmd service logs --raw "$svc" 2>/dev/null >> "$LOGS" || true
done

grep 'CSS_SCENARIO_RESULT' "$LOGS" | while IFS= read -r line; do
  line_run=$(get_kv "$line" run_id || true)
  [ -z "$RUN_ID" ] || [ "$line_run" = "$RUN_ID" ] || continue
  scenario=$(get_kv "$line" scenario || true)
  node=$(get_kv "$line" node || true)
  service=$(get_kv "$line" service || true)
  volume=$(get_kv "$line" volume || true)
  mode=$(get_kv "$line" mode || true)
  write=$(get_kv "$line" write || true)
  engine=$(get_kv "$line" engine || true)
  crypt=$(get_kv "$line" crypt || true)
  backup=$(get_kv "$line" backup || true)
  operations=$(get_kv "$line" operations || true)
  expected=$(get_kv "$line" expected_min_writers || true)
  actual_count=$(get_kv "$line" actual_writer_count || true)
  actual_seen=$(get_kv "$line" actual_writers_seen || true)
  status=$(get_kv "$line" status || true)
  notes=$(get_kv "$line" notes || true)
  backend=$(backend_check "$scenario" "$node" "$crypt")
  final=$status
  case "$backend" in
    FAIL:*) final=FAIL ;;
  esac
  opts="cs.mode:$mode,cs.write:$write,cs.engine:$engine,cs.crypt:$crypt,cs.backup:$backup"
  actual_volume="writer_count:$actual_count,writers:$actual_seen"
  expected_text="min_writers:$expected"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$scenario" "$node" "$service" "$volume" "$opts" "$operations" "$expected_text" "$actual_volume" "$backend" "$final" "$notes" >> "$TSV"
done

pass_count=$(awk -F '\t' 'NR>1 && $10=="PASS"{n++} END{print n+0}' "$TSV")
fail_count=$(awk -F '\t' 'NR>1 && $10=="FAIL"{n++} END{print n+0}' "$TSV")
row_count=$(awk 'NR>1{n++} END{print n+0}' "$TSV")

{
  echo "# CSS Scenario Test Report"
  echo
  echo "- Stack: \`$STACK\`"
  echo "- Run id: \`$RUN_ID\`"
  echo "- Rows: $row_count"
  echo "- Passed: $pass_count"
  echo "- Failed: $fail_count"
  if [ "$backend_ready" = "1" ]; then
    echo "- Backend direct check: enabled"
  else
    echo "- Backend direct check: skipped or unavailable"
  fi
  echo
  echo "| Scenario | Node | Volume | Options | Expected | Volume state | Backend state | Status |"
  echo "| --- | --- | --- | --- | --- | --- | --- | --- |"
  awk -F '\t' 'NR>1 {printf "| `%s` | `%s` | `%s` | `%s` | `%s` | `%s` | `%s` | **%s** |\n",$1,$2,$4,$5,$7,$8,$9,$10}' "$TSV"
} > "$MD"

echo "CSS_SCENARIO_REPORT_OK run_id=$RUN_ID rows=$row_count pass=$pass_count fail=$fail_count tsv=$TSV md=$MD logs=$LOGS"
[ "$fail_count" -eq 0 ]
