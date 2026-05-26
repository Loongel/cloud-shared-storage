#!/bin/sh
set -eu

STACK=${STACK:-css_scenario}
RUN_ID=${CSS_TEST_RUN_ID:-}
PROFILE=${CSS_TEST_PROFILE:-full}
NODE_NAMES=${CSS_TEST_NODE_NAMES:-}
WRITER_NODE=${CSS_TEST_WRITER_NODE:-}
TIMEOUT=${CSS_TEST_TIMEOUT:-240}
OUT_DIR=${OUT_DIR:-}
CHECK_BACKEND=1
RUN_CONTROLS=1
BACKEND_CURL_MAX_TIME=${CSS_TEST_BACKEND_CURL_MAX_TIME:-10}
BACKEND_CURL_CONNECT_TIMEOUT=${CSS_TEST_BACKEND_CURL_CONNECT_TIMEOUT:-5}
SERVER_ENV=${SERVER_ENV:-/etc/cs-storage/server.env}
DAEMON_ENV=${DAEMON_ENV:-/etc/cs-storage/daemon.env}
STACK_FILE=${STACK_FILE:-}
DAEMON_NODE_ID=

usage() {
  cat <<'EOF'
Usage: scripts/css-scenario-test-report.sh [options]

Collect CSS scenario stack results and write machine-readable plus Markdown reports.

Options:
  --stack NAME          Stack name, default css_scenario.
  --run-id ID           Run id.
  --profile PROFILE     full, core, smoke, backup-only, or shared-multi-only.
  --node-names CSV      Selected Swarm node hostnames.
  --writer-node NAME    Deterministic writer for shared-single scenarios.
  --timeout SECONDS     Wait timeout for workload tasks, default 240.
  --out-dir DIR         Report directory, default reports/css-scenario-<run-id>.
  --stack-file FILE     Rendered stack file to archive with the report.
  --no-backend-check    Skip direct WebDAV backend checks.
  --no-controls         Skip host-side control and negative tests.
  --server-env FILE     Server env used for backend credentials, default /etc/cs-storage/server.env.
  --daemon-env FILE     Daemon env used for Kopia checks, default /etc/cs-storage/daemon.env.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --stack) shift; STACK=$1 ;;
    --run-id) shift; RUN_ID=$1 ;;
    --profile) shift; PROFILE=$1 ;;
    --node-names) shift; NODE_NAMES=$1 ;;
    --writer-node) shift; WRITER_NODE=$1 ;;
    --timeout) shift; TIMEOUT=$1 ;;
    --out-dir) shift; OUT_DIR=$1 ;;
    --stack-file) shift; STACK_FILE=$1 ;;
    --no-backend-check) CHECK_BACKEND=0 ;;
    --no-controls) RUN_CONTROLS=0 ;;
    --server-env) shift; SERVER_ENV=$1 ;;
    --daemon-env) shift; DAEMON_ENV=$1 ;;
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

SCENARIOS="$ROOT/deploy/scenario-test/scenarios.tsv"

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

read_systemd_env_value() {
  unit=$1
  key=$2
  systemctl show "$unit" -p Environment --value 2>/dev/null | tr ' ' '\n' | awk -F= -v k="$key" '$1 == k {sub(/^[^=]*=/, ""); print; found=1; exit} END {exit found ? 0 : 1}'
}

read_daemon_value() {
  key=$1
  read_env_value "$DAEMON_ENV" "$key" 2>/dev/null || read_systemd_env_value cs-storage-daemon.service "$key"
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

scenario_meta() {
  id=$1
  awk -F '\t' -v id="$id" 'NR > 1 && $1 == id {print $0; found=1; exit} END {exit found ? 0 : 1}' "$SCENARIOS"
}

meta_field() {
  line=$1
  idx=$2
  printf '%s\n' "$line" | awk -F '\t' -v i="$idx" '{print $i}'
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
  DAEMON_NODE_ID=$(read_daemon_value CS_NODE_ID 2>/dev/null || true)
  auth_file=$(read_env_value "$SERVER_ENV" CS_BACKEND_AUTH_HEADER_FILE 2>/dev/null || true)
  user_file=$(read_env_value "$SERVER_ENV" CS_BACKEND_USER_FILE 2>/dev/null || true)
  pass_file=$(read_env_value "$SERVER_ENV" CS_BACKEND_PASSWORD_FILE 2>/dev/null || true)
  [ -n "$BACKEND_URL" ] || return
  if [ -n "$auth_file" ] && sudo -n test -r "$auth_file" 2>/dev/null; then
    BACKEND_AUTH_HEADER=$(sudo -n sed -n '1p' "$auth_file")
    backend_ready=1
    return
  fi
  if [ -n "$user_file" ] && [ -n "$pass_file" ] && sudo -n test -r "$user_file" 2>/dev/null && sudo -n test -r "$pass_file" 2>/dev/null; then
    BACKEND_USER=$(sudo -n sed -n '1p' "$user_file")
    BACKEND_PASSWORD=$(sudo -n sed -n '1p' "$pass_file")
    backend_ready=1
  fi
}

backend_node_candidates() {
  node=$1
  printf '%s\n' "$node"
  case "$node" in
    *.*) ;;
    *) printf '%s.netbird.cloud\n' "$node" ;;
  esac
  if [ -n "$DAEMON_NODE_ID" ]; then
    printf '%s\n' "$DAEMON_NODE_ID"
  fi
}

backend_marker_rel() {
  storage_node=$1
  scenario=$2
  writer_node=$3
  docker_volume=$4
  printf 'nodes/%s/volumes/%s/css-scenario-test/%s/%s/writers/%s.txt' "$storage_node" "$docker_volume" "$RUN_ID" "$scenario" "$writer_node"
}

backend_cipher_rel() {
  storage_node=$1
  docker_volume=$2
  printf 'nodes/%s/volumes/%s/cipher/gocryptfs.conf' "$storage_node" "$docker_volume"
}

backend_sqlite_rel() {
  storage_node=$1
  docker_volume=$2
  printf 'nodes/%s/volumes/%s/main.db' "$storage_node" "$docker_volume"
}

curl_backend() {
  rel=$1
  url=$(join_url "$BACKEND_URL" "$rel")
  if [ -n "$BACKEND_AUTH_HEADER" ]; then
    curl -fsS --connect-timeout "$BACKEND_CURL_CONNECT_TIMEOUT" --max-time "$BACKEND_CURL_MAX_TIME" -H "Authorization: $BACKEND_AUTH_HEADER" "$url"
  else
    curl -fsS --connect-timeout "$BACKEND_CURL_CONNECT_TIMEOUT" --max-time "$BACKEND_CURL_MAX_TIME" -u "$BACKEND_USER:$BACKEND_PASSWORD" "$url"
  fi
}

marker_content() {
  scenario=$1
  node=$2
  mode=$3
  write=$4
  engine=$5
  crypt=$6
  backup=$7
  workload=$8
  role=$9
  {
    printf 'run_id=%s\n' "$RUN_ID"
    printf 'scenario=%s\n' "$scenario"
    printf 'node=%s\n' "$node"
    printf 'role=%s\n' "$role"
    printf 'volume=css_%s\n' "$scenario"
    printf 'mode=%s\n' "$mode"
    printf 'write=%s\n' "$write"
    printf 'engine=%s\n' "$engine"
    printf 'crypt=%s\n' "$crypt"
    printf 'backup=%s\n' "$backup"
    printf 'workload=%s\n' "$workload"
  }
}

marker_role_for() {
  workload=$1
  case "$workload" in
    private-file) echo private-writer ;;
    shared-single-file) echo shared-writer ;;
    shared-multi-sqlite) echo sqlite-writer ;;
    shared-multi-auto) echo auto-writer ;;
    *) echo multi-writer ;;
  esac
}

backend_check() {
  scenario=$1
  crypt=$2
  expected_visible=$3
  mode=$4
  write=$5
  engine=$6
  backup=$7
  workload=$8
  volume=$9
  docker_volume="${STACK}_${volume}"
  if [ "$backend_ready" != "1" ]; then
    printf 'SKIP:backend_config_unavailable'
    return
  fi
  if [ -z "$expected_visible" ] || [ "$expected_visible" = none ]; then
    printf 'SKIP:no_expected_backend_paths'
    return
  fi
  role=$(marker_role_for "$workload")
  result=PASS
  detail=
  for node in $(printf '%s\n' "$expected_visible" | tr ',' ' '); do
    [ -n "$node" ] || continue
    tmp=$(mktemp /tmp/css-backend.XXXXXX)
    if [ "$crypt" = "true" ]; then
      plaintext_found=0
      for storage_node in $(backend_node_candidates "$node" | awk '!seen[$0]++'); do
        rel=$(backend_marker_rel "$storage_node" "$scenario" "$node" "$docker_volume")
        if curl_backend "$rel" > "$tmp" 2>/dev/null; then
          plaintext_found=1
          break
        fi
      done
      if [ "$plaintext_found" = "1" ]; then
        result=FAIL
        detail="${detail}${detail:+,}$node:plaintext_visible"
      else
        detail="${detail}${detail:+,}$node:plaintext_absent"
      fi
      rm -f "$tmp"
      continue
    fi
    if [ "$workload" = "shared-multi-sqlite" ]; then
      deadline=$(( $(date +%s) + 60 ))
      while :; do
        fetched=0
        for storage_node in $(backend_node_candidates "$node" | awk '!seen[$0]++'); do
          rel=$(backend_sqlite_rel "$storage_node" "$docker_volume")
          if curl_backend "$rel" > "$tmp" 2>/dev/null; then
            fetched=1
            break
          fi
        done
        [ "$fetched" = "1" ] && break
        [ "$(date +%s)" -ge "$deadline" ] && break
        sleep 2
      done
      if [ "$fetched" = "1" ]; then
        if command -v sqlite3 >/dev/null 2>&1; then
          integrity=$(sqlite3 "$tmp" "PRAGMA integrity_check;" 2>/dev/null || echo error)
          if [ "$integrity" = ok ]; then
            detail="${detail}${detail:+,}$node:sqlite_ok"
          else
            result=FAIL
            detail="${detail}${detail:+,}$node:sqlite_integrity_$integrity"
          fi
        else
          detail="${detail}${detail:+,}$node:sqlite_found"
        fi
      else
        result=FAIL
        detail="${detail}${detail:+,}$node:sqlite_missing"
      fi
      rm -f "$tmp"
      continue
    fi
    deadline=$(( $(date +%s) + 60 ))
    while :; do
      fetched=0
      for storage_node in $(backend_node_candidates "$node" | awk '!seen[$0]++'); do
        rel=$(backend_marker_rel "$storage_node" "$scenario" "$node" "$docker_volume")
        legacy_rel="nodes/$storage_node/css-scenario-test/$RUN_ID/$scenario/writers/$node.txt"
        if curl_backend "$rel" > "$tmp" 2>/dev/null || curl_backend "$legacy_rel" > "$tmp" 2>/dev/null; then
          fetched=1
          break
        fi
      done
      [ "$fetched" = "1" ] && break
      [ "$(date +%s)" -ge "$deadline" ] && break
      sleep 2
    done
    if [ "$fetched" = "1" ]; then
      expected_sha=$(marker_content "$scenario" "$node" "$mode" "$write" "$engine" "$crypt" "$backup" "$workload" "$role" | sha256sum | awk '{print $1}')
      actual_sha=$(sha256sum "$tmp" | awk '{print $1}')
      if [ "$expected_sha" = "$actual_sha" ]; then
        detail="${detail}${detail:+,}$node:sha_ok"
      else
        result=FAIL
        detail="${detail}${detail:+,}$node:sha_mismatch"
      fi
    else
      result=FAIL
      detail="${detail}${detail:+,}$node:missing"
    fi
    rm -f "$tmp"
  done
  if [ "$crypt" = "true" ]; then
    cipher_ok=0
    for node in $(printf '%s\n' "$expected_visible" | tr ',' ' '); do
      for storage_node in $(backend_node_candidates "$node" | awk '!seen[$0]++'); do
        if curl_backend "$(backend_cipher_rel "$storage_node" "$docker_volume")" >/dev/null 2>&1 || curl_backend "nodes/$storage_node/cipher/gocryptfs.conf" >/dev/null 2>&1; then
          cipher_ok=1
          break
        fi
      done
      [ "$cipher_ok" = "1" ] && break
    done
    if [ "$cipher_ok" = "1" ]; then
      detail="${detail}${detail:+,}cipher_present"
    else
      result=FAIL
      detail="${detail}${detail:+,}cipher_missing"
    fi
  fi
  printf '%s:%s' "$result" "${detail:-ok}"
}

backup_check() {
  backup=$1
  volume=$2
  [ "$backup" = true ] || { printf 'SKIP:backup_false'; return; }
  config=$(read_daemon_value CS_KOPIA_CONFIG_PATH 2>/dev/null || true)
  repo=$(read_daemon_value CS_KOPIA_REPOSITORY 2>/dev/null || true)
  password=$(read_daemon_value CS_KOPIA_PASSWORD 2>/dev/null || true)
  if [ -z "$password" ]; then
    password_file=$(read_daemon_value CS_KOPIA_PASSWORD_FILE 2>/dev/null || true)
    if [ -n "$password_file" ] && [ -s "$password_file" ]; then
      IFS= read -r password < "$password_file" || password=
    fi
  fi
  if [ -z "$config" ] && [ -z "$repo" ]; then
    printf 'BLOCKED:kopia_config_missing'
    return
  fi
  if ! command -v kopia >/dev/null 2>&1; then
    printf 'BLOCKED:kopia_binary_missing'
    return
  fi
  docker_volume="${STACK}_${volume}"
  source="/mnt/cs_storage/vols/$docker_volume/mount"
  tmp=$(mktemp /tmp/css-kopia-snapshots.XXXXXX)
  if [ -n "$config" ]; then
    if [ -n "$password" ]; then
      KOPIA_PASSWORD=$password kopia --config-file "$config" snapshot list --all --json "$source" > "$tmp" 2>/dev/null || true
    else
      kopia --config-file "$config" snapshot list --all --json "$source" > "$tmp" 2>/dev/null || true
    fi
  else
    if [ -n "$password" ]; then
      KOPIA_REPOSITORY=$repo KOPIA_PASSWORD=$password kopia snapshot list --all --json "$source" > "$tmp" 2>/dev/null || true
    else
      KOPIA_REPOSITORY=$repo kopia snapshot list --all --json "$source" > "$tmp" 2>/dev/null || true
    fi
  fi
  if grep -q "\"description\":\"cs-storage:$docker_volume\"" "$tmp"; then
    rm -f "$tmp"
    printf 'PASS:kopia_snapshot_found'
    return
  fi
  if grep -q "\"description\":\"cs-storage:$volume\"" "$tmp"; then
    rm -f "$tmp"
    printf 'PASS:kopia_snapshot_found_legacy_name'
    return
  fi
  rm -f "$tmp"
  printf 'FAIL:kopia_snapshot_missing:%s' "$docker_volume"
}

wait_for_services() {
  start=$(date +%s)
  while :; do
    active=0
    for svc in $(docker_cmd stack services --format '{{.Name}}' "$STACK" 2>/dev/null || true); do
      states=$(docker_cmd service ps --no-trunc --format '{{.CurrentState}}' "$svc" 2>/dev/null || true)
      if printf '%s\n' "$states" | grep -Eq '^(New|Pending|Assigned|Accepted|Preparing|Ready|Starting|Running) '; then
        active=1
      fi
    done
    [ "$active" = "0" ] && break
    now=$(date +%s)
    if [ $((now - start)) -ge "$TIMEOUT" ]; then
      echo "timeout waiting for stack tasks; collecting partial results" >&2
      break
    fi
    sleep 3
  done
}

service_error_status() {
  svc=$1
  err=$(docker_cmd service ps --no-trunc --format '{{.Error}}' "$svc" 2>/dev/null | sed '/^$/d' | sed -n '1p' | tr ' \t' '_' | tr -d '"' || true)
  [ -n "$err" ] || err=no_result_log
  case "$err" in
    *requires_CS_GLUSTER_REMOTE*|*LiteFS*|*litefs*|*kopia*|*KOPIA*|*missing_sqlite3*|*requires_CS_KOPIA*)
      printf 'BLOCKED\t%s' "$err"
      ;;
    *)
      printf 'FAIL\t%s' "$err"
      ;;
  esac
}

run_control_tests() {
  controls=$1
  printf 'control\toperation\texpected\tactual\tstatus\tnotes\n' > "$controls"
  base=$(printf '%s' "$RUN_ID" | tr -c 'A-Za-z0-9_.-' '_')

  for engine in auto static sqlite; do
    for crypt in false true; do
      for backup in false true; do
        name="css_ctrl_${base}_${engine}_${crypt}_${backup}"
        if docker_cmd volume create -d css -o cs.mode=private -o cs.write=multi -o cs.engine="$engine" -o cs.crypt="$crypt" -o cs.backup="$backup" "$name" >/tmp/css-ctrl.$$ 2>&1; then
          docker_cmd volume rm "$name" >/dev/null 2>&1 || true
          printf 'NEG-PRIVATE-MULTI\tcreate private+multi %s/%s/%s\tvalidation_error\tcreated\tFAIL\tunexpected_success\n' "$engine" "$crypt" "$backup" >> "$controls"
        elif grep -q 'cs.write=multi requires cs.mode=shared' /tmp/css-ctrl.$$; then
          printf 'NEG-PRIVATE-MULTI\tcreate private+multi %s/%s/%s\tvalidation_error\tvalidation_error\tPASS\tok\n' "$engine" "$crypt" "$backup" >> "$controls"
        else
          actual=$(tr '\n' ' ' < /tmp/css-ctrl.$$ | sed 's/[[:space:]]\\+/ /g')
          printf 'NEG-PRIVATE-MULTI\tcreate private+multi %s/%s/%s\tvalidation_error\t%s\tFAIL\tunexpected_error\n' "$engine" "$crypt" "$backup" "$actual" >> "$controls"
        fi
      done
    done
  done
  rm -f /tmp/css-ctrl.$$

  for bad in mode write engine crypt backup; do
    name="css_ctrl_${base}_bad_$bad"
    opts="-o cs.mode=private -o cs.write=single -o cs.engine=auto -o cs.crypt=false -o cs.backup=false"
    case "$bad" in
      mode) opts="-o cs.mode=bad -o cs.write=single -o cs.engine=auto -o cs.crypt=false -o cs.backup=false" ;;
      write) opts="-o cs.mode=private -o cs.write=bad -o cs.engine=auto -o cs.crypt=false -o cs.backup=false" ;;
      engine) opts="-o cs.mode=private -o cs.write=single -o cs.engine=bad -o cs.crypt=false -o cs.backup=false" ;;
      crypt) opts="-o cs.mode=private -o cs.write=single -o cs.engine=auto -o cs.crypt=bad -o cs.backup=false" ;;
      backup) opts="-o cs.mode=private -o cs.write=single -o cs.engine=auto -o cs.crypt=false -o cs.backup=bad" ;;
    esac
    # shellcheck disable=SC2086
    if docker_cmd volume create -d css $opts "$name" >/tmp/css-ctrl.$$ 2>&1; then
      docker_cmd volume rm "$name" >/dev/null 2>&1 || true
      printf 'NEG-BAD-ENUM\tbad %s\tvalidation_error\tcreated\tFAIL\tunexpected_success\n' "$bad" >> "$controls"
    else
      printf 'NEG-BAD-ENUM\tbad %s\tvalidation_error\tvalidation_error\tPASS\tok\n' "$bad" >> "$controls"
    fi
  done
  rm -f /tmp/css-ctrl.$$

  if command -v cs-storage-admin >/dev/null 2>&1; then
    tmp=$(mktemp /tmp/css-compose.XXXXXX.yml)
    {
      echo 'volumes:'
      echo '  bad:'
      echo '    driver: css'
      echo '    labels:'
      echo '      flush: "true"'
    } > "$tmp"
    if cs-storage-admin render-compose -in "$tmp" >/tmp/css-render.$$ 2>&1; then
      printf 'CTRL-FLUSH-LABEL\trender label flush\trejected\trendered\tFAIL\tunexpected_success\n' >> "$controls"
    else
      printf 'CTRL-FLUSH-LABEL\trender label flush\trejected\trejected\tPASS\tok\n' >> "$controls"
    fi
    rm -f "$tmp" /tmp/css-render.$$
  else
    printf 'CTRL-FLUSH-LABEL\trender label flush\trejected\tmissing_admin\tBLOCKED\tcs-storage-admin_missing\n' >> "$controls"
  fi
}

load_backend_config
wait_for_services

if [ -z "$RUN_ID" ]; then
  RUN_ID=$(docker_cmd stack services --format '{{.Name}}' "$STACK" 2>/dev/null | sed -n '1p')
fi
[ -n "$RUN_ID" ] || { echo "missing --run-id" >&2; exit 1; }

if [ -z "$OUT_DIR" ]; then
  OUT_DIR="reports/css-scenario-$RUN_ID"
fi
mkdir -p "$OUT_DIR"
TSV="$OUT_DIR/results.tsv"
MD="$OUT_DIR/report.md"
LOGS="$OUT_DIR/service-logs.txt"
CONTROLS="$OUT_DIR/controls.tsv"
PREFLIGHT="$OUT_DIR/preflight.tsv"
STACK_ARCHIVE="$OUT_DIR/stack.rendered.yml"
: > "$LOGS"

if [ -n "$STACK_FILE" ] && [ -f "$STACK_FILE" ] && [ "$(readlink -f "$STACK_FILE")" != "$(readlink -m "$STACK_ARCHIVE")" ]; then
  cp "$STACK_FILE" "$STACK_ARCHIVE"
fi

printf 'scenario\tnode\tservice\tvolume\tmode\twrite\tengine\tcrypt\tbackup\tworkload\trole\twriter_node\texpected_visible\tactual_visible\tmissing\tunexpected\toperations\town_sha\tsqlite_integrity\tsqlite_rows\tbackend\tbackup_check\tstatus\tnotes\n' > "$TSV"

for svc in $(docker_cmd stack services --format '{{.Name}}' "$STACK" 2>/dev/null | sort); do
  docker_cmd service logs --raw "$svc" 2>/dev/null >> "$LOGS" || true
done

if grep -q 'CSS_SCENARIO_RESULT' "$LOGS"; then
  grep 'CSS_SCENARIO_RESULT' "$LOGS" | while IFS= read -r line; do
    line_run=$(get_kv "$line" run_id || true)
    [ "$line_run" = "$RUN_ID" ] || continue
    scenario=$(get_kv "$line" scenario || true)
    node=$(get_kv "$line" node || true)
    service=$(get_kv "$line" service || true)
    volume=$(get_kv "$line" volume || true)
    mode=$(get_kv "$line" mode || true)
    write=$(get_kv "$line" write || true)
    engine=$(get_kv "$line" engine || true)
    crypt=$(get_kv "$line" crypt || true)
    backup=$(get_kv "$line" backup || true)
    workload=$(get_kv "$line" workload || true)
    role=$(get_kv "$line" role || true)
    writer_node=$(get_kv "$line" writer_node || true)
    expected_visible=$(get_kv "$line" expected_visible || true)
    actual_visible=$(get_kv "$line" actual_visible || true)
    missing=$(get_kv "$line" missing || true)
    unexpected=$(get_kv "$line" unexpected || true)
    operations=$(get_kv "$line" operations || true)
    own_sha=$(get_kv "$line" own_sha || true)
    sqlite_integrity=$(get_kv "$line" sqlite_integrity || true)
    sqlite_rows=$(get_kv "$line" sqlite_rows || true)
    status=$(get_kv "$line" status || true)
    notes=$(get_kv "$line" notes || true)
    backend=$(backend_check "$scenario" "$crypt" "$expected_visible" "$mode" "$write" "$engine" "$backup" "$workload" "$volume")
    bkp=$(backup_check "$backup" "$volume")
    final=$status
    case "$backend" in FAIL:*) final=FAIL ;; esac
    case "$bkp" in FAIL:*) final=FAIL ;; BLOCKED:*) [ "$final" = PASS ] && final=BLOCKED ;; esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$scenario" "$node" "$service" "$volume" "$mode" "$write" "$engine" "$crypt" "$backup" "$workload" "$role" "$writer_node" "$expected_visible" "$actual_visible" "$missing" "$unexpected" "$operations" "$own_sha" "$sqlite_integrity" "$sqlite_rows" "$backend" "$bkp" "$final" "$notes" >> "$TSV"
  done
fi

for svc in $(docker_cmd stack services --format '{{.Name}}' "$STACK" 2>/dev/null | sort); do
  sid=${svc#${STACK}_}
  if awk -F '\t' -v s="$sid" 'NR > 1 && $1 == s {found=1} END {exit found ? 0 : 1}' "$TSV"; then
    continue
  fi
  meta=$(scenario_meta "$sid" 2>/dev/null || true)
  [ -n "$meta" ] || continue
  mode=$(meta_field "$meta" 2)
  write=$(meta_field "$meta" 3)
  engine=$(meta_field "$meta" 4)
  crypt=$(meta_field "$meta" 5)
  backup=$(meta_field "$meta" 6)
  workload=$(meta_field "$meta" 7)
  se=$(service_error_status "$svc")
  st=$(printf '%s' "$se" | awk -F '\t' '{print $1}')
  note=$(printf '%s' "$se" | awk -F '\t' '{print $2}')
  printf '%s\t%s\t%s\tcss_%s\t%s\t%s\t%s\t%s\t%s\t%s\tna\t%s\tna\tna\tna\tna\tservice_not_started\tna\tna\tna\tSKIP:not_mounted\tSKIP:not_requested\t%s\t%s\n' \
    "$sid" "NO_TASK" "$svc" "$sid" "$mode" "$write" "$engine" "$crypt" "$backup" "$workload" "${WRITER_NODE:-na}" "$st" "$note" >> "$TSV"
done

if [ "$RUN_CONTROLS" = "1" ]; then
  run_control_tests "$CONTROLS"
else
  printf 'control\toperation\texpected\tactual\tstatus\tnotes\n' > "$CONTROLS"
fi

pass_count=$(awk -F '\t' 'NR>1 && $23=="PASS"{n++} END{print n+0}' "$TSV")
fail_count=$(awk -F '\t' 'NR>1 && $23=="FAIL"{n++} END{print n+0}' "$TSV")
blocked_count=$(awk -F '\t' 'NR>1 && $23=="BLOCKED"{n++} END{print n+0}' "$TSV")
row_count=$(awk 'NR>1{n++} END{print n+0}' "$TSV")
control_fail=$(awk -F '\t' 'NR>1 && $5=="FAIL"{n++} END{print n+0}' "$CONTROLS")
control_blocked=$(awk -F '\t' 'NR>1 && $5=="BLOCKED"{n++} END{print n+0}' "$CONTROLS")
preflight_fail=0
preflight_blocked=0
if [ -f "$PREFLIGHT" ]; then
  preflight_fail=$(awk -F '\t' 'NR>1 && $3=="FAIL"{n++} END{print n+0}' "$PREFLIGHT")
  preflight_blocked=$(awk -F '\t' 'NR>1 && $3=="BLOCKED"{n++} END{print n+0}' "$PREFLIGHT")
fi

{
  echo "# CSS Scenario Test Report"
  echo
  echo "- Stack: \`$STACK\`"
  echo "- Run id: \`$RUN_ID\`"
  echo "- Profile: \`$PROFILE\`"
  echo "- Nodes: \`${NODE_NAMES:-unknown}\`"
  echo "- Writer node: \`${WRITER_NODE:-unknown}\`"
  echo "- Scenario rows: $row_count"
  echo "- Passed: $pass_count"
  echo "- Failed: $fail_count"
  echo "- Blocked: $blocked_count"
  echo "- Control failures: $control_fail"
  echo "- Control blocked: $control_blocked"
  echo "- Preflight failures: $preflight_fail"
  echo "- Preflight blocked: $preflight_blocked"
  if [ "$backend_ready" = "1" ]; then
    echo "- Backend direct check: enabled"
  else
    echo "- Backend direct check: skipped or unavailable"
  fi
  echo
  echo "## Scenario Results"
  echo
  echo "| Scenario | Node | Options | Workload | Expected | Actual | Backend | Backup | Status | Notes |"
  echo "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"
  awk -F '\t' 'NR>1 {opts="cs.mode="$5",cs.write="$6",cs.engine="$7",cs.crypt="$8",cs.backup="$9; printf "| `%s` | `%s` | `%s` | `%s` | `%s` | `%s` | `%s` | `%s` | **%s** | `%s` |\n",$1,$2,opts,$10,$13,$14,$21,$22,$23,$24}' "$TSV"
  echo
  echo "## Control Results"
  echo
  echo "| Control | Operation | Expected | Actual | Status | Notes |"
  echo "| --- | --- | --- | --- | --- | --- |"
  awk -F '\t' 'NR>1 {printf "| `%s` | `%s` | `%s` | `%s` | **%s** | `%s` |\n",$1,$2,$3,$4,$5,$6}' "$CONTROLS"
  if [ -f "$PREFLIGHT" ]; then
    echo
    echo "## Preflight Results"
    echo
    echo "| Check | Target | Status | Notes |"
    echo "| --- | --- | --- | --- |"
    awk -F '\t' 'NR>1 {printf "| `%s` | `%s` | **%s** | `%s` |\n",$1,$2,$3,$4}' "$PREFLIGHT"
  fi
} > "$MD"

echo "CSS_SCENARIO_REPORT_OK run_id=$RUN_ID profile=$PROFILE rows=$row_count pass=$pass_count fail=$fail_count blocked=$blocked_count control_fail=$control_fail control_blocked=$control_blocked preflight_fail=$preflight_fail preflight_blocked=$preflight_blocked tsv=$TSV controls=$CONTROLS md=$MD logs=$LOGS"
[ "$fail_count" -eq 0 ] && [ "$blocked_count" -eq 0 ] && [ "$control_fail" -eq 0 ] && [ "$control_blocked" -eq 0 ] && [ "$preflight_fail" -eq 0 ] && [ "$preflight_blocked" -eq 0 ]
