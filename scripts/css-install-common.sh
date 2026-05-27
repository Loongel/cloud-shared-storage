#!/bin/sh
set -eu

CSS_RELEASE_VERSION=${CSS_RELEASE_VERSION:-0.1.22}
CSS_REPO_RAW=${CSS_REPO_RAW:-https://raw.githubusercontent.com/Loongel/cloud-shared-storage/main}
CSS_DEB_URL=${CSS_DEB_URL:-https://github.com/Loongel/cloud-shared-storage/releases/download/v${CSS_RELEASE_VERSION}/cs-storage_${CSS_RELEASE_VERSION}_amd64.deb}
CSS_INSTALLER_URL=${CSS_INSTALLER_URL:-$CSS_REPO_RAW/scripts/cs-storage-systemd-node-install.sh}

ENV_DIR=${ENV_DIR:-/etc/cs-storage}
SECRET_DIR=${SECRET_DIR:-$ENV_DIR/secrets}
DRIVER_NAME=${DRIVER_NAME:-css}
NODE_ID=${NODE_ID:-}
CSS_BIND_INTERFACE=${CSS_BIND_INTERFACE:-wt0}
INSTALL_DEPS=${INSTALL_DEPS:-1}
ENABLE_NOW=${ENABLE_NOW:-1}
FORCE_SECRET_UPDATE=${FORCE_SECRET_UPDATE:-0}
PRINT_CLIENT_SECRET=${CSS_PRINT_CLIENT_SECRET:-1}
CLIENT_COMMAND_FILE=${CLIENT_COMMAND_FILE:-$ENV_DIR/client-install-command.sh}
CSS_OUTPUT_COLOR=${CSS_OUTPUT_COLOR:-auto}

SERVER_ADDR=${SERVER_ADDR:-}
SERVER_PORT=${SERVER_PORT:-}
SERVER_URL=${SERVER_URL:-}
PUBLIC_URL=${PUBLIC_URL:-}

BACKEND_URL=${BACKEND_URL:-}
BACKEND_AUTH_HEADER=${BACKEND_AUTH_HEADER:-}
BACKEND_AUTH_HEADER_FILE=${BACKEND_AUTH_HEADER_FILE:-}
BACKEND_USER=${BACKEND_USER:-}
BACKEND_USER_FILE=${BACKEND_USER_FILE:-}
BACKEND_PASSWORD=${BACKEND_PASSWORD:-}
BACKEND_PASSWORD_FILE=${BACKEND_PASSWORD_FILE:-}

NODE_SECRET=${NODE_SECRET:-}
NODE_SECRET_FILE=${NODE_SECRET_FILE:-}
GOCRYPTFS_PASSWORD=${GOCRYPTFS_PASSWORD:-}
GOCRYPTFS_PASSWORD_FILE=${GOCRYPTFS_PASSWORD_FILE:-}
GENERATED_SECRETS=""
REUSED_SECRETS=""
UPDATED_SECRETS=""
SECRET_STATUS_FILE=${SECRET_STATUS_FILE:-$(mktemp /tmp/css-secret-status.XXXXXX)}

usage_common() {
  role=$1
  cat <<EOF
Usage: $0 [options]

One-command Cloud Shared Storage (CSS) $role installer.

Common options:
  --driver-name NAME             Docker VolumeDriver name, default css.
  --node-id ID                   Node id, default NetBird FQDN, then hostname.
  --bind-interface IFACE         Default server bind interface, default wt0.
  --node-secret VALUE            Shared S/C node secret; client must match server.
  --node-secret-file FILE        File containing shared S/C node secret.
  --gocryptfs-password VALUE     Cluster gocryptfs passphrase; generated if absent.
  --gocryptfs-password-file FILE
  --force-secret-update          Allow replacing existing secret files after backup.
  --no-print-client-secret       Do not print/store inline client install secret.
  --install-deps                 Install host dependencies, default.
  --no-install-deps              Do not install host dependencies.
  --deb-url URL                  CSS .deb URL, default GitHub Release v$CSS_RELEASE_VERSION.

EOF
  case "$role" in
    server|all)
      cat <<'EOF'
Server options, required for server/all:
  --backend-url URL              WebDAV/S3 HTTP backend URL.
  --backend-user USER            Backend username.
  --backend-password PASSWORD    Backend password.
  --backend-user-file FILE       Backend username file.
  --backend-password-file FILE   Backend password file.
  --backend-auth-header HEADER   Prebuilt backend Authorization header.
  --backend-auth-header-file FILE
  --server-port PORT             S-side port; auto-picks 18080-18100 if absent.
  --server-addr ADDR             S-side listen address; overrides wt0 default.
  --public-url URL               Optional public URL returned to clients.

EOF
      ;;
  esac
  case "$role" in
    client|all)
      cat <<'EOF'
Client options, required for client-only:
  --server-url URL               S-side URL, for example http://10.0.0.10:18080.

EOF
      ;;
  esac
  cat <<EOF
Fresh server/all requires backend URL and backend auth. Existing installs reuse
existing values from $ENV_DIR and $SECRET_DIR. Server/all prints and stores a
client bootstrap command with node_secret inline by default, so the command is
sensitive. Pass --no-print-client-secret to suppress that convenience output.

Secret safety:
  - node_secret is generated only on first server/all install when absent.
  - client-only never generates node_secret; use the server-printed command or
    pass --node-secret/--node-secret-file with the server's same value.
  - gocryptfs_password is generated only on first client/all install when absent.
  - existing secret files are reused; different new values are refused unless
    --force-secret-update is passed, and the old file is backed up first.
EOF
}

die() {
  echo "$*" >&2
  exit 1
}

need_root() {
  test "$(id -u)" = 0 || die "must run as root"
}

download_file() {
  url=$1
  dst=$2
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dst"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$dst" "$url"
  else
    die "missing curl or wget"
  fi
}

random_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    dd if=/dev/urandom bs=32 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n'
  fi
}

ensure_secret_dir() {
  install -d -m 0755 "$ENV_DIR"
  install -d -m 0700 "$SECRET_DIR"
}

write_secret_value() {
  value=$1
  dst=$2
  umask 077
  printf '%s\n' "$value" > "$dst"
}

fingerprint_file() {
  file=$1
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  else
    cksum "$file" | awk '{print $1}'
  fi
}

record_generated() { echo "generated $1" >> "$SECRET_STATUS_FILE"; }
record_reused() { echo "reused $1" >> "$SECRET_STATUS_FILE"; }
record_updated() { echo "updated $1" >> "$SECRET_STATUS_FILE"; }

backup_secret() {
  dst=$1
  ts=$(date +%Y%m%d-%H%M%S)
  cp -p "$dst" "$dst.BAK.$ts"
}

install_secret_file_safely() {
  label=$1
  src=$2
  dst=$3
  test -s "$src" || die "missing $label file: $src"
  if test -s "$dst"; then
    if cmp -s "$src" "$dst"; then
      record_reused "$label:$dst"
      printf '%s\n' "$dst"
      return
    fi
    test "$FORCE_SECRET_UPDATE" = "1" || die "refusing to replace existing $label at $dst; pass --force-secret-update only for intentional rotation"
    backup_secret "$dst"
    install -m 0600 "$src" "$dst"
    record_updated "$label:$dst"
    printf '%s\n' "$dst"
    return
  fi
  install -m 0600 "$src" "$dst"
  record_updated "$label:$dst"
  printf '%s\n' "$dst"
}

secret_path_from_value_or_file() {
  sp_label=$1
  sp_value=$2
  sp_file=$3
  sp_dst=$4
  sp_generate=$5
  if test -n "$sp_file"; then
    install_secret_file_safely "$sp_label" "$sp_file" "$sp_dst"
    return
  fi
  if test -n "$sp_value"; then
    sp_tmp=$(mktemp /tmp/css-secret.XXXXXX)
    write_secret_value "$sp_value" "$sp_tmp"
    install_secret_file_safely "$sp_label" "$sp_tmp" "$sp_dst"
    rm -f "$sp_tmp"
    return
  fi
  if test -s "$sp_dst"; then
    record_reused "$sp_label:$sp_dst"
    printf '%s\n' "$sp_dst"
    return
  fi
  if test "$sp_generate" = "yes"; then
    write_secret_value "$(random_secret)" "$sp_dst"
    record_generated "$sp_label:$sp_dst"
    printf '%s\n' "$sp_dst"
    return
  fi
  return 1
}

port_free() {
  port=$1
  if command -v ss >/dev/null 2>&1; then
    ! ss -ltn "sport = :$port" 2>/dev/null | awk 'NR > 1 {found=1} END {exit found ? 0 : 1}'
    return
  fi
  if command -v lsof >/dev/null 2>&1; then
    ! lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
    return
  fi
  return 0
}

pick_server_port() {
  if test -n "$SERVER_PORT"; then
    printf '%s\n' "$SERVER_PORT"
    return
  fi
  for p in 18080 18081 18082 18083 18084 18085 18086 18087 18088 18089 18090 18091 18092 18093 18094 18095 18096 18097 18098 18099 18100; do
    if port_free "$p"; then
      printf '%s\n' "$p"
      return
    fi
  done
  die "no free CSS server port in 18080-18100; pass --server-port"
}

interface_ipv4() {
  iface=$1
  command -v ip >/dev/null 2>&1 || return 1
  ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{split($4, a, "/"); print a[1]; exit}'
}

netbird_fqdn() {
  command -v netbird >/dev/null 2>&1 || return 1
  netbird status 2>/dev/null | awk -F': *' '$1 == "FQDN" && $2 != "" {print $2; exit}'
}

host_fallback() {
  hostname -f 2>/dev/null || hostname
}

default_node_id() {
  nb_fqdn=$(netbird_fqdn || true)
  if test -n "$nb_fqdn"; then
    printf '%s\n' "$nb_fqdn"
    return
  fi
  host_fallback
}

default_public_host() {
  bind_ip=$1
  nb_fqdn=$(netbird_fqdn || true)
  if test -n "$nb_fqdn"; then
    printf '%s\n' "$nb_fqdn"
    return
  fi
  if test -n "$bind_ip"; then
    printf '%s\n' "$bind_ip"
    return
  fi
  host_fallback
}

addr_port() {
  addr=$1
  printf '%s' "$addr" | awk -F: '{print $NF}'
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

color_enabled() {
  test "$CSS_OUTPUT_COLOR" = "always" && return 0
  test "$CSS_OUTPUT_COLOR" = "never" && return 1
  test -t 1 || return 1
  test -z "${NO_COLOR:-}"
}

color_start() {
  code=$1
  color_enabled && printf '\033[%sm' "$code" || true
}

color_reset() {
  color_enabled && printf '\033[0m' || true
}

color_line() {
  code=$1
  text=$2
  if color_enabled; then
    printf '\033[%sm%s\033[0m\n' "$code" "$text"
  else
    printf '%s\n' "$text"
  fi
}

summary_rule() {
  color_line '1;36' '======================================================================'
}

summary_title() {
  title=$1
  summary_rule
  color_line '1;36' "  $title"
  summary_rule
}

summary_warn() {
  color_line '1;33' "$1"
}

summary_success() {
  color_line '1;32' "$1"
}

read_secret_line() {
  file=$1
  test -s "$file" || return 1
  IFS= read -r value < "$file" || return 1
  printf '%s\n' "$value"
}

client_install_command() {
  server_url=$1
  node_secret=$2
  gocryptfs_password=$3
  printf 'curl -fsSL %s/scripts/css-install-client.sh \\\n' "$CSS_REPO_RAW"
  printf '  | sudo sh -s -- \\\n'
  printf '  --server-url '
  shell_quote "$server_url"
  printf ' \\\n'
  printf '  --node-secret '
  shell_quote "$node_secret"
  printf ' \\\n'
  printf '  --gocryptfs-password '
  shell_quote "$gocryptfs_password"
}

write_client_install_command_file() {
  command_text=$1
  command_dir=$(dirname -- "$CLIENT_COMMAND_FILE")
  install -d -m 0750 "$command_dir"
  if getent group cs-storage >/dev/null 2>&1; then
    chown root:cs-storage "$command_dir" 2>/dev/null || true
    chmod 0750 "$command_dir" 2>/dev/null || true
  fi
  umask 077
  {
    printf '#!/bin/sh\n'
    printf 'set -eu\n'
    printf '%s\n' "$command_text"
  } > "$CLIENT_COMMAND_FILE"
  chmod 0700 "$CLIENT_COMMAND_FILE"
}

read_env_value() {
  file=$1
  key=$2
  test -f "$file" || return 1
  awk -F= -v k="$key" '$1 == k {sub(/^[^=]*=/, ""); print; found=1; exit} END {exit found ? 0 : 1}' "$file"
}

find_installer() {
  if test "${CSS_INSTALLER_PREFER_INSTALLED:-0}" = "1" && test -x /usr/sbin/cs-storage-systemd-node-install; then
    printf '%s\n' /usr/sbin/cs-storage-systemd-node-install
    return
  fi
  if test "${CSS_INSTALLER_PREFER_INSTALLED:-0}" = "1" && test -x /usr/local/sbin/cs-storage-systemd-node-install; then
    printf '%s\n' /usr/local/sbin/cs-storage-systemd-node-install
    return
  fi
  dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
  if test -f "$dir/cs-storage-systemd-node-install.sh"; then
    printf '%s\n' "$dir/cs-storage-systemd-node-install.sh"
    return
  fi
  tmp=$(mktemp /tmp/css-node-install.XXXXXX)
  download_file "$CSS_INSTALLER_URL" "$tmp"
  chmod 0755 "$tmp"
  printf '%s\n' "$tmp"
}

parse_common_args() {
  while test "$#" -gt 0; do
    case "$1" in
      --driver-name) shift; DRIVER_NAME=$1 ;;
      --bind-interface) shift; CSS_BIND_INTERFACE=$1 ;;
      --node-id) shift; NODE_ID=$1 ;;
      --node-secret) shift; NODE_SECRET=$1 ;;
      --node-secret-file) shift; NODE_SECRET_FILE=$1 ;;
      --force-secret-update) FORCE_SECRET_UPDATE=1 ;;
      --print-client-secret) PRINT_CLIENT_SECRET=1 ;;
      --no-print-client-secret) PRINT_CLIENT_SECRET=0 ;;
      --gocryptfs-password) shift; GOCRYPTFS_PASSWORD=$1 ;;
      --gocryptfs-password-file) shift; GOCRYPTFS_PASSWORD_FILE=$1 ;;
      --backend-url) shift; BACKEND_URL=$1 ;;
      --backend-user) shift; BACKEND_USER=$1 ;;
      --backend-password) shift; BACKEND_PASSWORD=$1 ;;
      --backend-user-file) shift; BACKEND_USER_FILE=$1 ;;
      --backend-password-file) shift; BACKEND_PASSWORD_FILE=$1 ;;
      --backend-auth-header) shift; BACKEND_AUTH_HEADER=$1 ;;
      --backend-auth-header-file) shift; BACKEND_AUTH_HEADER_FILE=$1 ;;
      --server-port) shift; SERVER_PORT=$1 ;;
      --server-addr) shift; SERVER_ADDR=$1 ;;
      --server-url) shift; SERVER_URL=$1 ;;
      --public-url) shift; PUBLIC_URL=$1 ;;
      --deb-url) shift; CSS_DEB_URL=$1 ;;
      --install-deps) INSTALL_DEPS=1 ;;
      --no-install-deps) INSTALL_DEPS=0 ;;
      --enable-now) ENABLE_NOW=1 ;;
      --no-enable-now) ENABLE_NOW=0 ;;
      -h|--help) return 2 ;;
      *) die "unknown argument: $1" ;;
    esac
    shift
  done
  return 0
}

css_install() {
  role=$1
  shift
  if ! parse_common_args "$@"; then
    usage_common "$role"
    exit 0
  fi

  need_root
  ensure_secret_dir
  if test -z "$NODE_ID"; then
    NODE_ID=$(default_node_id)
  fi

  case "$role" in
    server|all) node_secret_generate=yes ;;
    *) node_secret_generate=no ;;
  esac
  node_secret_file=$(secret_path_from_value_or_file node_secret "$NODE_SECRET" "$NODE_SECRET_FILE" "$SECRET_DIR/node_secret" "$node_secret_generate" || true)
  test -n "$node_secret_file" || die "--node-secret or --node-secret-file is required for a fresh client install; use the client command printed by the server installer"
  gocrypt_file=
  case "$role" in
    server|all)
      gocrypt_file=$(secret_path_from_value_or_file gocryptfs_password "$GOCRYPTFS_PASSWORD" "$GOCRYPTFS_PASSWORD_FILE" "$SECRET_DIR/gocryptfs_password" yes)
      ;;
  esac
  installer=$(find_installer)

  set -- --role "$role" --driver-name "$DRIVER_NAME" --deb-url "$CSS_DEB_URL" --node-id "$NODE_ID" --node-secret-file "$node_secret_file" --bind-interface "$CSS_BIND_INTERFACE"

  if test "$INSTALL_DEPS" = "1"; then
    export ACK_INSTALL_HOST_DEPS=yes
    set -- "$@" --install-deps
  else
    set -- "$@" --no-install-deps
  fi
  if test "$ENABLE_NOW" = "1"; then
    set -- "$@" --enable-now
  else
    set -- "$@" --no-enable-now
  fi

  case "$role" in
    server|all)
      bind_ip=$(interface_ipv4 "$CSS_BIND_INTERFACE" || true)
      public_host=$(default_public_host "$bind_ip")
      if test -z "$BACKEND_URL"; then
        BACKEND_URL=$(read_env_value "$ENV_DIR/server.env" CS_BACKEND_URL || true)
      fi
      test -n "$BACKEND_URL" || die "--backend-url is required for fresh server/all install"
      if test -z "$SERVER_ADDR"; then
        SERVER_ADDR=$(read_env_value "$ENV_DIR/server.env" CS_SERVER_ADDR || true)
        if test -z "$SERVER_ADDR"; then
          port=$(pick_server_port)
          if test -n "$bind_ip"; then
            SERVER_ADDR="$bind_ip:$port"
          else
            SERVER_ADDR=":$port"
          fi
        else
          port=$(addr_port "$SERVER_ADDR")
        fi
      else
        port=$(addr_port "$SERVER_ADDR")
      fi
      if test -z "$PUBLIC_URL"; then
        PUBLIC_URL=$(read_env_value "$ENV_DIR/server.env" CS_PUBLIC_URL || true)
      fi
      if test -z "$PUBLIC_URL" && test -n "$public_host" && test -n "$port"; then
        PUBLIC_URL="http://$public_host:$port"
      fi
      set -- "$@" --server-addr "$SERVER_ADDR" --backend-url "$BACKEND_URL"
      test -z "$PUBLIC_URL" || set -- "$@" --public-url "$PUBLIC_URL"

      if test -z "$BACKEND_AUTH_HEADER_FILE"; then
        BACKEND_AUTH_HEADER_FILE=$(read_env_value "$ENV_DIR/server.env" CS_BACKEND_AUTH_HEADER_FILE || true)
      fi
      if test -z "$BACKEND_USER_FILE"; then
        BACKEND_USER_FILE=$(read_env_value "$ENV_DIR/server.env" CS_BACKEND_USER_FILE || true)
      fi
      if test -z "$BACKEND_PASSWORD_FILE"; then
        BACKEND_PASSWORD_FILE=$(read_env_value "$ENV_DIR/server.env" CS_BACKEND_PASSWORD_FILE || true)
      fi

      backend_auth_file=$(secret_path_from_value_or_file backend_auth_header "$BACKEND_AUTH_HEADER" "$BACKEND_AUTH_HEADER_FILE" "$SECRET_DIR/backend_auth_header" no || true)
      if test -n "$backend_auth_file"; then
        set -- "$@" --backend-auth-header-file "$backend_auth_file"
      else
        backend_user_file=$(secret_path_from_value_or_file backend_user "$BACKEND_USER" "$BACKEND_USER_FILE" "$SECRET_DIR/backend_user" no || true)
        backend_password_file=$(secret_path_from_value_or_file backend_password "$BACKEND_PASSWORD" "$BACKEND_PASSWORD_FILE" "$SECRET_DIR/backend_password" no || true)
        test -n "$backend_user_file" || die "backend auth is required: pass --backend-auth-header-file, or --backend-user/--backend-password"
        test -n "$backend_password_file" || die "backend auth is required: pass --backend-auth-header-file, or --backend-user/--backend-password"
        set -- "$@" --backend-user-file "$backend_user_file" --backend-password-file "$backend_password_file"
      fi

      if test "$role" = all && test -z "$SERVER_URL"; then
        SERVER_URL=$(read_env_value "$ENV_DIR/daemon.env" CS_SERVER_URL || true)
        if test -z "$SERVER_URL"; then
          if test -n "$PUBLIC_URL"; then
            SERVER_URL="$PUBLIC_URL"
          elif test -n "$bind_ip"; then
            SERVER_URL="http://$bind_ip:$port"
          else
            SERVER_URL="http://127.0.0.1:$port"
          fi
        fi
      fi
      ;;
  esac

  case "$role" in
    client|all)
      if test -z "$SERVER_URL"; then
        SERVER_URL=$(read_env_value "$ENV_DIR/daemon.env" CS_SERVER_URL || true)
      fi
      test -n "$SERVER_URL" || die "--server-url is required for client"
      if test -z "$gocrypt_file"; then
        gocrypt_file=$(secret_path_from_value_or_file gocryptfs_password "$GOCRYPTFS_PASSWORD" "$GOCRYPTFS_PASSWORD_FILE" "$SECRET_DIR/gocryptfs_password" yes)
      fi
      set -- "$@" --server-url "$SERVER_URL" --gocryptfs-password-file "$gocrypt_file"
      ;;
  esac

  export CSS_ALLOW_SECRET_REPLACE=yes
  sh "$installer" "$@"
  css_print_secret_summary "$role" "$node_secret_file" "${gocrypt_file:-}" "${SERVER_URL:-$PUBLIC_URL}"
}

css_print_secret_summary() {
  role=$1
  node_secret_file=$2
  gocrypt_file=${3:-}
  server_url=${4:-}
  echo
  summary_title "CSS INSTALL RESULT - SAVE THIS OUTPUT"
  echo "CSS_INSTALL_SECRET_BACKUP_REQUIRED"
  echo "  node_secret_file=$node_secret_file"
  echo "  node_secret_sha256=$(fingerprint_file "$node_secret_file")"
  if test -n "$gocrypt_file"; then
    echo "  gocryptfs_password_file=$gocrypt_file"
    echo "  gocryptfs_password_sha256=$(fingerprint_file "$gocrypt_file")"
  fi
  test -z "$server_url" || echo "  server_url=$server_url"
  echo "  generated=$(awk '$1 == "generated" {sub($1 FS, ""); printf "%s ", $0}' "$SECRET_STATUS_FILE" 2>/dev/null)"
  echo "  reused=$(awk '$1 == "reused" {sub($1 FS, ""); printf "%s ", $0}' "$SECRET_STATUS_FILE" 2>/dev/null)"
  echo "  updated=$(awk '$1 == "updated" {sub($1 FS, ""); printf "%s ", $0}' "$SECRET_STATUS_FILE" 2>/dev/null)"
  case "$role" in
    server)
      echo "  expected_services=cs-storage-server.service"
      echo "  note=server-only install does not create daemon/plugin client config"
      echo "  local_driver_install=curl -fsSL $CSS_REPO_RAW/scripts/css-install-all.sh | sudo sh -s --"
      ;;
    client)
      echo "  expected_services=cs-storage-daemon.service cs-storage-plugin.service"
      ;;
    all)
      echo "  expected_services=cs-storage-server.service cs-storage-daemon.service cs-storage-plugin.service"
      ;;
  esac
  summary_warn "IMPORTANT: back up node_secret on server/all installs; every client must use the same node_secret."
  summary_warn "IMPORTANT: back up gocryptfs_password before using encrypted volumes; changing it makes old encrypted data unreadable."
  case "$role" in
    server|all)
      if test -n "$server_url"; then
        echo
        summary_title "CSS CLIENT INSTALL COMMAND - SECRET"
        if test "$PRINT_CLIENT_SECRET" = "1"; then
          node_secret_value=$(read_secret_line "$node_secret_file")
          gocrypt_value=$(read_secret_line "$gocrypt_file")
          command_text=$(client_install_command "$server_url" "$node_secret_value" "$gocrypt_value")
          write_client_install_command_file "$command_text"
          summary_warn "This command contains node_secret and gocryptfs_password. Treat it as a secret."
          echo "saved_script=$CLIENT_COMMAND_FILE"
          echo "run_saved_script=sudo sh $CLIENT_COMMAND_FILE"
          echo
          printf '  %s\n' "$command_text"
        else
          echo "  Inline secret output is disabled."
          echo "  Copy $node_secret_file and $gocrypt_file to each client or rerun without --no-print-client-secret."
          printf '  curl -fsSL %s/scripts/css-install-client.sh | sudo sh -s -- --server-url ' "$CSS_REPO_RAW"
          shell_quote "$server_url"
          printf ' --node-secret-file '
          shell_quote "$node_secret_file"
          printf ' --gocryptfs-password-file '
          shell_quote "$gocrypt_file"
          printf '\n'
        fi
        summary_rule
      fi
      ;;
    *)
      echo "IMPORTANT: scripts never print secret values for client-only installs."
      ;;
  esac
  summary_success "CSS_INSTALL_COMPLETE role=$role driver=$DRIVER_NAME"
}
