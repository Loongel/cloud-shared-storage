#!/bin/sh
set -eu

STACK=${STACK:-cs-storage-production-secrets-preflight}
IMAGE=${IMAGE:-alpine:3.20}
SMOKE=${SMOKE:-/tmp/cs-storage-production-secrets-preflight}
STRICT=${STRICT:-0}
NODES_MIN=${NODES_MIN:-}
ENV_DIR=${ENV_DIR:-/etc/cs-storage}
SECRET_DIR=${SECRET_DIR:-secrets}
CONTAINER_SECRET_DIR=${CONTAINER_SECRET_DIR:-/run/cs-storage-secrets}
SERVER_ENV=${SERVER_ENV:-server.env}
DAEMON_ENV=${DAEMON_ENV:-daemon.env}
PLUGIN_ENV=${PLUGIN_ENV:-plugin.env}
DOCKER_TIMEOUT=${DOCKER_TIMEOUT:-15s}
COLLECT_TIMEOUT=${COLLECT_TIMEOUT:-60s}
COLLECT_ATTEMPTS=${COLLECT_ATTEMPTS:-60}
SERVICE_WAIT_ATTEMPTS=${SERVICE_WAIT_ATTEMPTS:-40}
CLEANUP_WAIT_ATTEMPTS=${CLEANUP_WAIT_ATTEMPTS:-12}

docker_t() {
  timeout "$DOCKER_TIMEOUT" docker "$@"
}

rm -rf "$SMOKE"
mkdir -p "$SMOKE"

cleanup() {
  docker_t stack rm "$STACK" >/dev/null 2>&1 || true
  for _ in $(seq 1 "$CLEANUP_WAIT_ATTEMPTS"); do
    if ! docker_t stack ps "$STACK" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
}
trap cleanup EXIT

state=$(docker_t info --format '{{.Swarm.LocalNodeState}}')
if test "$state" != "active"; then
  echo "PRODUCTION_SECRETS_PREFLIGHT_SWARM_NOT_ACTIVE state=$state"
  exit 1
fi
active_nodes=$(docker_t node ls --format '{{.Status}}' | awk '$1 == "Ready" {n++} END {print n+0}')
if test -z "$NODES_MIN"; then
  NODES_MIN=$active_nodes
fi
if test "$active_nodes" -lt "$NODES_MIN"; then
  echo "PRODUCTION_SECRETS_PREFLIGHT_NOT_ENOUGH_NODES ready=$active_nodes min=$NODES_MIN"
  exit 1
fi

cat > "$SMOKE/stack.yml" <<EOF
version: "3.8"
services:
  probe:
    image: $IMAGE
    command:
      - /bin/sh
      - -c
      - |
        set -eu
        mkdir -p /www
        node=\$\$(cat /host/etc/hostname 2>/dev/null || hostname)
        env_dir=/host$ENV_DIR
        secret_dir=\$\$env_dir/$SECRET_DIR
        check_mode() {
          file=\$\$1
          label=\$\$2
          mode=\$\$(stat -c %a "\$\$file" 2>/dev/null || echo unknown)
          echo "FOUND \$\$node \$\$label mode=\$\$mode"
          case "\$\$mode" in
            unknown) echo "WARN \$\$node \$\$label stat_failed" ;;
            400|600|0400|0600) : ;;
            *) echo "INSECURE_MODE \$\$node \$\$label mode=\$\$mode" ;;
          esac
        }
        get_key() {
          file=\$\$1
          key=\$\$2
          sed -n "s/^\$\$key=//p" "\$\$file" | tail -n 1
        }
        check_key() {
          file=\$\$1
          label=\$\$2
          key=\$\$3
          required=\$\$4
          value=\$\$(get_key "\$\$file" "\$\$key")
          if test -z "\$\$value"; then
            if test "\$\$required" = "required"; then
              echo "MISSING_KEY \$\$node \$\$label \$\$key"
            else
              echo "WARN \$\$node \$\$label optional_missing \$\$key"
            fi
            return
          fi
          case "\$\$value" in
            change-me|replace-with-*|*example.test*|*example-volume*) echo "PLACEHOLDER \$\$node \$\$label \$\$key" ;;
            *) echo "KEY_OK \$\$node \$\$label \$\$key" ;;
          esac
        }
        check_file_secret() {
          label=\$\$1
          key=\$\$2
          path=\$\$3
          case "\$\$path" in
            $CONTAINER_SECRET_DIR/*) host_file=\$\$secret_dir/\$\${path#$CONTAINER_SECRET_DIR/} ;;
            /*) host_file=/host\$\$path ;;
            *) echo "INVALID_FILE_REF \$\$node \$\$label \$\$key path=\$\$path"; return ;;
          esac
          if ! test -s "\$\$host_file"; then
            echo "MISSING_FILE_REF \$\$node \$\$label \$\$key path=\$\$path"
            return
          fi
          check_mode "\$\$host_file" "\$\${label}_\$\${key}_FILE"
          echo "KEY_FILE_OK \$\$node \$\$label \$\$key"
        }
        check_key_either() {
          file=\$\$1
          label=\$\$2
          key=\$\$3
          value=\$\$(get_key "\$\$file" "\$\$key")
          file_value=\$\$(get_key "\$\$file" "\$\${key}_FILE")
          if test -n "\$\$value"; then
            check_key "\$\$file" "\$\$label" "\$\$key" required
          elif test -n "\$\$file_value"; then
            case "\$\$file_value" in
              change-me|replace-with-*|*example.test*|*example-volume*) echo "PLACEHOLDER \$\$node \$\$label \$\${key}_FILE" ;;
              *) echo "KEY_OK \$\$node \$\$label \$\${key}_FILE" ;;
            esac
            check_file_secret "\$\$label" "\$\${key}" "\$\$file_value"
          else
            echo "MISSING_KEY \$\$node \$\$label \$\$key"
          fi
        }
        check_file() {
          label=\$\$1
          name=\$\$2
          shift 2
          file=\$\$env_dir/\$\$name
          if ! test -s "\$\$file"; then
            echo "MISSING_FILE \$\$node \$\$label $ENV_DIR/\$\$name"
            return
          fi
          check_mode "\$\$file" "\$\$label"
          while test "\$\$#" -gt 0; do
            check_key "\$\$file" "\$\$label" "\$\$1" required
            shift
          done
        }
        {
          echo "NODE \$\$node"
          check_file server $SERVER_ENV CS_BACKEND_URL
          if test -s "\$\$env_dir/$SERVER_ENV"; then
            check_key_either "\$\$env_dir/$SERVER_ENV" server CS_NODE_SECRET_KEY
            auth_header=\$\$(get_key "\$\$env_dir/$SERVER_ENV" CS_BACKEND_AUTH_HEADER)
            auth_header_file=\$\$(get_key "\$\$env_dir/$SERVER_ENV" CS_BACKEND_AUTH_HEADER_FILE)
            auth_user=\$\$(get_key "\$\$env_dir/$SERVER_ENV" CS_BACKEND_USER)
            auth_user_file=\$\$(get_key "\$\$env_dir/$SERVER_ENV" CS_BACKEND_USER_FILE)
            auth_pass=\$\$(get_key "\$\$env_dir/$SERVER_ENV" CS_BACKEND_PASSWORD)
            auth_pass_file=\$\$(get_key "\$\$env_dir/$SERVER_ENV" CS_BACKEND_PASSWORD_FILE)
            if test -z "\$\$auth_header\$\$auth_header_file" && { test -z "\$\$auth_user\$\$auth_user_file" || test -z "\$\$auth_pass\$\$auth_pass_file"; }; then
              echo "MISSING_AUTH \$\$node server backend_auth"
            else
              case "\$\$auth_header\$\$auth_header_file\$\$auth_user\$\$auth_user_file\$\$auth_pass\$\$auth_pass_file" in
                *change-me*|*replace-with-*|*example.test*|*example-volume*) echo "PLACEHOLDER \$\$node server backend_auth" ;;
                *) echo "KEY_OK \$\$node server backend_auth_present" ;;
              esac
            fi
          fi
          check_file daemon $DAEMON_ENV CS_SERVER_URL CS_NODE_ID
          if test -s "\$\$env_dir/$DAEMON_ENV"; then
            check_key_either "\$\$env_dir/$DAEMON_ENV" daemon CS_NODE_SECRET_KEY
            check_key_either "\$\$env_dir/$DAEMON_ENV" daemon CS_GOCRYPTFS_PASSWORD
          fi
          if test -s "\$\$env_dir/$SERVER_ENV" && test -s "\$\$env_dir/$DAEMON_ENV"; then
            server_secret=\$\$(get_key "\$\$env_dir/$SERVER_ENV" CS_NODE_SECRET_KEY)
            daemon_secret=\$\$(get_key "\$\$env_dir/$DAEMON_ENV" CS_NODE_SECRET_KEY)
            if test -z "\$\$server_secret"; then server_secret=\$\$(get_key "\$\$env_dir/$SERVER_ENV" CS_NODE_SECRET_KEY_FILE); fi
            if test -z "\$\$daemon_secret"; then daemon_secret=\$\$(get_key "\$\$env_dir/$DAEMON_ENV" CS_NODE_SECRET_KEY_FILE); fi
            if test -n "\$\$server_secret" && test -n "\$\$daemon_secret"; then
              if test "\$\$server_secret" = "\$\$daemon_secret"; then
                echo "KEY_MATCH \$\$node server_daemon CS_NODE_SECRET_KEY"
              else
                echo "MISMATCH_KEY \$\$node server_daemon CS_NODE_SECRET_KEY"
              fi
            fi
          fi
          check_file plugin $PLUGIN_ENV CS_PLUGIN_SOCKET CS_DAEMON_SOCKET CS_DOCKER_SOCKET CS_PLUGIN_TIMEOUT
        } > /www/result.txt
        cat /www/result.txt
        issues=\$\$(awk '\$\$1 == "MISSING_FILE" || \$\$1 == "MISSING_KEY" || \$\$1 == "PLACEHOLDER" || \$\$1 == "INSECURE_MODE" || \$\$1 == "MISMATCH_KEY" || \$\$1 == "MISSING_AUTH" || \$\$1 == "MISSING_FILE_REF" || \$\$1 == "INVALID_FILE_REF" {n++} END {print n+0}' /www/result.txt)
        test "\$\$issues" -eq 0
    volumes:
      - type: bind
        source: /
        target: /host
        read_only: true
    deploy:
      mode: global
      restart_policy:
        condition: none
EOF

docker_t stack deploy -c "$SMOKE/stack.yml" "$STACK" >/dev/null
service="${STACK}_probe"
ps_timeouts=0
nodes=0
completed=0
failed=0
for _ in $(seq 1 "$SERVICE_WAIT_ATTEMPTS"); do
  if docker_t service ps "$service" --no-trunc --format '{{.Node}}|{{.CurrentState}}|{{.Error}}' > "$SMOKE/service-ps.txt" 2>/dev/null; then
    ps_timeouts=0
    nodes=$(awk -F'|' '$2 ~ /^Running/ {print $1}' "$SMOKE/service-ps.txt" | sort -u | wc -l | tr -d ' ')
    completed=$(awk -F'|' '$2 ~ /^Complete/ {print $1}' "$SMOKE/service-ps.txt" | sort -u | wc -l | tr -d ' ')
    failed=$(awk -F'|' '$2 ~ /^Failed|^Rejected/ || $3 != "" {n++} END {print n+0}' "$SMOKE/service-ps.txt")
  else
    ps_timeouts=$((ps_timeouts + 1))
    nodes=0
    completed=0
    failed=0
  fi
  if test "$failed" -gt 0 || test "$completed" -ge "$NODES_MIN"; then
    break
  fi
  if test "$ps_timeouts" -ge 3; then
    echo "PRODUCTION_SECRETS_PREFLIGHT_DOCKER_TIMEOUTS service=$service consecutive=$ps_timeouts"
    exit 1
  fi
  sleep 1
done
if test "$failed" -gt 0 || test "$completed" -lt "$NODES_MIN"; then
  docker_t service ps "$service" --no-trunc || true
  echo "PRODUCTION_SECRETS_PREFLIGHT_NOT_COMPLETE completed=$completed failed=$failed running=$nodes min=$NODES_MIN ready=$active_nodes"
  exit 1
fi

for _ in $(seq 1 "$COLLECT_ATTEMPTS"); do
  docker_t service logs --raw --tail 5000 "$service" > "$SMOKE/logs.txt" 2> "$SMOKE/collect.err" || true
  logged_nodes=$(awk '$1 == "NODE" {print $2}' "$SMOKE/logs.txt" | sort -u | wc -l | tr -d ' ')
  if test "$logged_nodes" -ge "$NODES_MIN"; then
    break
  fi
  sleep 1
done

cat "$SMOKE/logs.txt"
logged_nodes=$(awk '$1 == "NODE" {print $2}' "$SMOKE/logs.txt" | sort -u | wc -l | tr -d ' ')
issues=$(awk '$1 == "MISSING_FILE" || $1 == "MISSING_KEY" || $1 == "PLACEHOLDER" || $1 == "INSECURE_MODE" || $1 == "MISMATCH_KEY" || $1 == "MISSING_AUTH" || $1 == "MISSING_FILE_REF" || $1 == "INVALID_FILE_REF" {n++} END {print n+0}' "$SMOKE/logs.txt")
warnings=$(awk '$1 == "WARN" {n++} END {print n+0}' "$SMOKE/logs.txt")

trap - EXIT
cleanup

if test "$logged_nodes" -lt "$NODES_MIN"; then
  echo "PRODUCTION_SECRETS_PREFLIGHT_LOGS_PARTIAL logged_nodes=$logged_nodes completed=$completed min=$NODES_MIN image=$IMAGE"
fi
if test "$issues" -gt 0; then
  echo "PRODUCTION_SECRETS_PREFLIGHT_ISSUES issues=$issues warnings=$warnings logged_nodes=$logged_nodes completed=$completed ready=$active_nodes env_dir=$ENV_DIR"
  if test "$STRICT" = "1"; then
    exit 1
  fi
else
  echo "PRODUCTION_SECRETS_PREFLIGHT_OK warnings=$warnings logged_nodes=$logged_nodes completed=$completed ready=$active_nodes env_dir=$ENV_DIR"
fi
