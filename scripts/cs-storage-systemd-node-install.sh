#!/bin/sh
set -eu

ROLE=${ROLE:-all}
PREFIX=${PREFIX:-/usr/local/bin}
SYSTEMD_DIR=${SYSTEMD_DIR:-/etc/systemd/system}
ENV_DIR=${ENV_DIR:-/etc/cs-storage}
SECRET_DIR=${SECRET_DIR:-$ENV_DIR/secrets}
STATE_DIR=${STATE_DIR:-/var/lib/cs-storage}
LOG_DIR=${LOG_DIR:-/var/log/cs-storage}
ROOT_DIR=${ROOT_DIR:-/mnt/cs_storage/vols}
CSS_DRIVER_NAME=${CSS_DRIVER_NAME:-css}
BIN_DIR=${BIN_DIR:-}
IMAGE=${IMAGE:-}
DEB=${DEB:-}
DEB_URL=${DEB_URL:-}
INSTALL_DEPS=${INSTALL_DEPS:-0}
ENABLE_NOW=${ENABLE_NOW:-1}
RESTART_SERVICES=${RESTART_SERVICES:-1}
SERVICE_USER=${SERVICE_USER:-cs-storage}
SERVICE_GROUP=${SERVICE_GROUP:-$SERVICE_USER}
CSS_ALLOW_SECRET_REPLACE=${CSS_ALLOW_SECRET_REPLACE:-no}

CS_SERVER_ADDR=${CS_SERVER_ADDR:-:18080}
CS_SERVER_URL=${CS_SERVER_URL:-}
CS_PUBLIC_URL=${CS_PUBLIC_URL:-}
CS_BACKEND_URL=${CS_BACKEND_URL:-}
CS_BACKEND_AUTH_HEADER_FILE=${CS_BACKEND_AUTH_HEADER_FILE:-}
CS_BACKEND_USER_FILE=${CS_BACKEND_USER_FILE:-}
CS_BACKEND_PASSWORD_FILE=${CS_BACKEND_PASSWORD_FILE:-}
CS_NODE_SECRET_KEY_FILE=${CS_NODE_SECRET_KEY_FILE:-}
CS_GOCRYPTFS_PASSWORD_FILE=${CS_GOCRYPTFS_PASSWORD_FILE:-}
CS_COORDINATOR_TOKEN_FILE=${CS_COORDINATOR_TOKEN_FILE:-}
CS_NODE_ID=${CS_NODE_ID:-$(hostname)}

usage() {
  cat <<'EOF'
Usage: scripts/cs-storage-systemd-node-install.sh [options]

Install CS-Storage as host systemd services on the current node.

Options:
  --role server|client|all       Services to install/start. all installs server+client.
  --driver-name NAME             Docker VolumeDriver name, default css.
  --deb PATH                     Install CS-Storage package from a local .deb first.
  --deb-url URL                  Download and install CS-Storage package from URL first.
  --bin-dir DIR                  Directory containing cs-storage-* binaries.
  --image IMAGE                  Docker image to extract binaries from when --bin-dir is absent.
  --server-addr ADDR             S-side listen address, default :18080.
  --server-url URL               URL C-side daemon uses for S-side /auth.
  --public-url URL               Optional public URL returned from /auth.
  --backend-url URL              WebDAV/S3 HTTP backend URL for S-side gateway.
  --backend-auth-header-file P   File containing prebuilt backend Authorization header.
  --backend-user-file P          File containing backend username.
  --backend-password-file P      File containing backend password.
  --node-secret-file P           File containing shared node JWT secret.
  --gocryptfs-password-file P    File containing gocryptfs passphrase.
  --coordinator-token-file P     Optional LiteFS/Consul-compatible token file.
  --node-id ID                   Node id for daemon, default hostname.
  --install-deps                 Install apt host dependencies. Requires ACK_INSTALL_HOST_DEPS=yes.
  --no-install-deps              Do not install apt dependencies.
  --enable-now                   Enable and start/restart selected services, default.
  --no-enable-now                Only install files and run systemctl daemon-reload.

Required for server role:
  --backend-url and --node-secret-file plus either backend auth-header file or user+password files.

Required for client role:
  --server-url, --node-secret-file, and --gocryptfs-password-file.

The script writes env files under /etc/cs-storage and references file-backed secrets.
It does not print secret values.

Recommended cross-node install:
  curl -fsSL <repo-raw-url>/scripts/cs-storage-systemd-node-install.sh -o /tmp/cs-install.sh
  sh /tmp/cs-install.sh --deb-url <github-release-deb-url> --role client ...
EOF
}

while test "$#" -gt 0; do
  case "$1" in
    --role) shift; ROLE=$1 ;;
    --driver-name) shift; CSS_DRIVER_NAME=$1 ;;
    --deb) shift; DEB=$1 ;;
    --deb-url) shift; DEB_URL=$1 ;;
    --bin-dir) shift; BIN_DIR=$1 ;;
    --image) shift; IMAGE=$1 ;;
    --server-addr) shift; CS_SERVER_ADDR=$1 ;;
    --server-url) shift; CS_SERVER_URL=$1 ;;
    --public-url) shift; CS_PUBLIC_URL=$1 ;;
    --backend-url) shift; CS_BACKEND_URL=$1 ;;
    --backend-auth-header-file) shift; CS_BACKEND_AUTH_HEADER_FILE=$1 ;;
    --backend-user-file) shift; CS_BACKEND_USER_FILE=$1 ;;
    --backend-password-file) shift; CS_BACKEND_PASSWORD_FILE=$1 ;;
    --node-secret-file) shift; CS_NODE_SECRET_KEY_FILE=$1 ;;
    --gocryptfs-password-file) shift; CS_GOCRYPTFS_PASSWORD_FILE=$1 ;;
    --coordinator-token-file) shift; CS_COORDINATOR_TOKEN_FILE=$1 ;;
    --node-id) shift; CS_NODE_ID=$1 ;;
    --install-deps) INSTALL_DEPS=1 ;;
    --no-install-deps) INSTALL_DEPS=0 ;;
    --enable-now) ENABLE_NOW=1 ;;
    --no-enable-now) ENABLE_NOW=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

case "$ROLE" in
  server|client|all) ;;
  *) echo "invalid role: $ROLE" >&2; exit 1 ;;
esac

need_root() {
  if test "$(id -u)" != "0"; then
    echo "must run as root" >&2
    exit 1
  fi
}

need_file() {
  label=$1
  path=$2
  if test -z "$path" || test ! -s "$path"; then
    echo "missing $label file: $path" >&2
    exit 1
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing command: $1" >&2; exit 1; }
}

role_has_server() { test "$ROLE" = server || test "$ROLE" = all; }
role_has_client() { test "$ROLE" = client || test "$ROLE" = all; }
existing_server_config() { test -f "$ENV_DIR/server.env"; }
existing_client_config() { test -f "$ENV_DIR/daemon.env" && test -f "$ENV_DIR/plugin.env"; }

validate_driver_name() {
  case "$CSS_DRIVER_NAME" in
    ""|*/*|*:*|*..*)
      echo "invalid driver name: $CSS_DRIVER_NAME" >&2
      exit 1
      ;;
  esac
  printf '%s' "$CSS_DRIVER_NAME" | grep -Eq '^[A-Za-z0-9_.-]+$' || {
    echo "invalid driver name: $CSS_DRIVER_NAME" >&2
    exit 1
  }
}

validate_inputs() {
  validate_driver_name
  if role_has_server; then
    test -n "$CS_BACKEND_URL" || { echo "server role requires --backend-url" >&2; exit 1; }
    need_file node-secret "$CS_NODE_SECRET_KEY_FILE"
    if test -n "$CS_BACKEND_AUTH_HEADER_FILE"; then
      need_file backend-auth-header "$CS_BACKEND_AUTH_HEADER_FILE"
    else
      need_file backend-user "$CS_BACKEND_USER_FILE"
      need_file backend-password "$CS_BACKEND_PASSWORD_FILE"
    fi
  fi
  if role_has_client; then
    test -n "$CS_SERVER_URL" || { echo "client role requires --server-url" >&2; exit 1; }
    need_file node-secret "$CS_NODE_SECRET_KEY_FILE"
    need_file gocryptfs-password "$CS_GOCRYPTFS_PASSWORD_FILE"
  fi
}

install_deps() {
  if test "$INSTALL_DEPS" != "1"; then
    return
  fi
  test "${ACK_INSTALL_HOST_DEPS:-}" = yes || {
    echo "refusing apt changes without ACK_INSTALL_HOST_DEPS=yes" >&2
    exit 1
  }
  need_cmd apt-get
  export DEBIAN_FRONTEND=noninteractive
  export DEBIAN_PRIORITY=critical
  export LC_ALL=C
  export LANG=C
  export LANGUAGE=C
  export NEEDRESTART_MODE=a
  apt-get update
  apt-get \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    install -y --no-install-recommends \
    ca-certificates fuse3 rclone gocryptfs glusterfs-client glusterfs-server sqlite3
}

download_file() {
  url=$1
  dst=$2
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dst"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$dst" "$url"
  else
    echo "missing curl or wget for --deb-url" >&2
    exit 1
  fi
}

install_deb_package() {
  if test -n "$DEB_URL"; then
    tmp=$(mktemp -d /tmp/cs-storage-deb.XXXXXX)
    DEB="$tmp/cs-storage.deb"
    download_file "$DEB_URL" "$DEB"
    chmod 0755 "$tmp"
    chmod 0644 "$DEB"
  fi
  if test -z "$DEB"; then
    return
  fi
  test -s "$DEB" || { echo "missing deb package: $DEB" >&2; exit 1; }
  export DEBIAN_FRONTEND=noninteractive
  export DEBIAN_PRIORITY=critical
  export LC_ALL=C
  export LANG=C
  export LANGUAGE=C
  export NEEDRESTART_MODE=a
  if command -v apt-get >/dev/null 2>&1; then
    apt-get \
      -o Dpkg::Options::=--force-confdef \
      -o Dpkg::Options::=--force-confold \
      install -y --reinstall "$DEB"
  else
    need_cmd dpkg
    dpkg -i "$DEB"
  fi
  BIN_DIR=
}

ensure_user_and_dirs() {
  if ! getent group "$SERVICE_GROUP" >/dev/null 2>&1; then
    groupadd --system "$SERVICE_GROUP"
  fi
  if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
    useradd --system --gid "$SERVICE_GROUP" --home-dir "$STATE_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"
  fi
  install -d -m 0755 "$PREFIX" "$SYSTEMD_DIR" "$ENV_DIR" "$SECRET_DIR" "$STATE_DIR" "$LOG_DIR" "$ROOT_DIR" /run/docker/plugins
  chown root:"$SERVICE_GROUP" "$ENV_DIR"
  chmod 0750 "$ENV_DIR"
  chown "$SERVICE_USER:$SERVICE_GROUP" "$STATE_DIR" "$LOG_DIR"
  chmod 0750 "$SECRET_DIR"
  chgrp "$SERVICE_GROUP" "$SECRET_DIR"
}

extract_image_bins() {
  test -n "$IMAGE" || return
  tmp=$(mktemp -d /tmp/cs-storage-image-bins.XXXXXX)
  cid=$(docker create "$IMAGE")
  cleanup() {
    docker rm "$cid" >/dev/null 2>&1 || true
    rm -rf "$tmp"
  }
  trap cleanup EXIT INT TERM
  for bin in cs-storage-server cs-storage-daemon cs-storage-plugin cs-storage-admin cs-storage-router litefs kopia; do
    docker cp "$cid:/usr/local/bin/$bin" "$tmp/$bin" 2>/dev/null || \
      docker cp "$cid:/usr/bin/$bin" "$tmp/$bin" 2>/dev/null || true
  done
  BIN_DIR=$tmp
}

install_binaries() {
  if test -z "$BIN_DIR" && test -z "$IMAGE"; then
    ok=1
    for bin in cs-storage-server cs-storage-daemon cs-storage-plugin cs-storage-admin cs-storage-router; do
      test -x "$PREFIX/$bin" || ok=0
    done
    if test "$ok" = "1"; then
      return
    fi
  fi
  if test -z "$BIN_DIR"; then
    extract_image_bins
  fi
  test -n "$BIN_DIR" || { echo "install a .deb first, or set --deb-url, --deb, --bin-dir, or --image" >&2; exit 1; }
  for bin in cs-storage-server cs-storage-daemon cs-storage-plugin cs-storage-admin cs-storage-router; do
    test -x "$BIN_DIR/$bin" || { echo "missing executable $BIN_DIR/$bin" >&2; exit 1; }
    install -m 0755 "$BIN_DIR/$bin" "$PREFIX/$bin"
  done
  for bin in litefs kopia; do
    if test -x "$BIN_DIR/$bin"; then
      install -m 0755 "$BIN_DIR/$bin" "$PREFIX/$bin"
    fi
  done
}

install_units() {
  src_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
  if test ! -d "$src_dir/deploy/systemd"; then
    for unit in cs-storage-server.service cs-storage-daemon.service cs-storage-plugin.service; do
      test -f "$SYSTEMD_DIR/$unit" || test -f "/lib/systemd/system/$unit" || {
        echo "missing unit $unit; install the .deb or run from repo checkout" >&2
        exit 1
      }
    done
    systemctl daemon-reload
    return
  fi
  for unit in cs-storage-server.service cs-storage-daemon.service cs-storage-plugin.service; do
    install -m 0644 "$src_dir/deploy/systemd/$unit" "$SYSTEMD_DIR/$unit"
  done
  systemctl daemon-reload
}

copy_secret() {
  src=$1
  dst=$2
  if test -n "$src"; then
    src_real=$(readlink -f "$src")
    dst_real=$(readlink -m "$dst")
    if test "$src_real" != "$dst_real"; then
      if test -s "$dst" && ! cmp -s "$src" "$dst"; then
        test "$CSS_ALLOW_SECRET_REPLACE" = yes || {
          echo "refusing to replace existing secret: $dst" >&2
          echo "set CSS_ALLOW_SECRET_REPLACE=yes only for an intentional credential rotation" >&2
          exit 1
        }
      fi
      install -m 0640 -o root -g "$SERVICE_GROUP" "$src" "$dst"
    else
      chown root:"$SERVICE_GROUP" "$dst"
      chmod 0640 "$dst"
    fi
  fi
}

write_envs() {
  secret_node="$SECRET_DIR/node_secret"
  secret_gocrypt="$SECRET_DIR/gocryptfs_password"
  secret_backend_user="$SECRET_DIR/backend_user"
  secret_backend_password="$SECRET_DIR/backend_password"
  secret_backend_auth="$SECRET_DIR/backend_auth_header"
  secret_coord="$SECRET_DIR/coordinator_token"

  copy_secret "$CS_NODE_SECRET_KEY_FILE" "$secret_node"
  copy_secret "$CS_GOCRYPTFS_PASSWORD_FILE" "$secret_gocrypt"
  copy_secret "$CS_BACKEND_USER_FILE" "$secret_backend_user"
  copy_secret "$CS_BACKEND_PASSWORD_FILE" "$secret_backend_password"
  copy_secret "$CS_BACKEND_AUTH_HEADER_FILE" "$secret_backend_auth"
  copy_secret "$CS_COORDINATOR_TOKEN_FILE" "$secret_coord"

  if role_has_server; then
    {
      printf 'CS_SERVER_ADDR=%s\n' "$CS_SERVER_ADDR"
      printf 'CS_NODE_SECRET_KEY_FILE=%s\n' "$secret_node"
      printf 'CS_BACKEND_URL=%s\n' "$CS_BACKEND_URL"
      if test -n "$CS_BACKEND_AUTH_HEADER_FILE"; then
        printf 'CS_BACKEND_AUTH_HEADER_FILE=%s\n' "$secret_backend_auth"
      else
        printf 'CS_BACKEND_USER_FILE=%s\n' "$secret_backend_user"
        printf 'CS_BACKEND_PASSWORD_FILE=%s\n' "$secret_backend_password"
      fi
      test -z "$CS_PUBLIC_URL" || printf 'CS_PUBLIC_URL=%s\n' "$CS_PUBLIC_URL"
      printf 'CS_TOKEN_TTL=12h\n'
      printf 'CS_SANDBOX_PREFIX=/nodes\n'
      printf 'CS_KV_PATH=%s/gateway-kv.json\n' "$STATE_DIR"
      test -z "$CS_COORDINATOR_TOKEN_FILE" || printf 'CS_COORDINATOR_TOKEN_FILE=%s\n' "$secret_coord"
    } > "$ENV_DIR/server.env"
    chown root:"$SERVICE_GROUP" "$ENV_DIR/server.env"
    chmod 0640 "$ENV_DIR/server.env"
  fi

  if role_has_client; then
    {
      printf 'CS_DAEMON_SOCKET=/run/cs-storage.sock\n'
      printf 'CS_ROOT_DIR=%s\n' "$ROOT_DIR"
      printf 'CS_SERVER_URL=%s\n' "$CS_SERVER_URL"
      printf 'CS_NODE_ID=%s\n' "$CS_NODE_ID"
      printf 'CS_NODE_SECRET_KEY_FILE=%s\n' "$secret_node"
      printf 'CS_ENABLE_CHATTR=true\n'
      printf 'CS_RECOVER_MOUNTS=true\n'
      printf 'CS_GOCRYPTFS_PASSWORD_FILE=%s\n' "$secret_gocrypt"
      printf 'CS_RCLONE_VFS_CACHE_MODE=writes\n'
      printf 'CS_RCLONE_VFS_WRITE_BACK=\n'
      printf 'CS_RCLONE_VFS_CACHE_MAX_SIZE=\n'
    } > "$ENV_DIR/daemon.env"
    chown root:"$SERVICE_GROUP" "$ENV_DIR/daemon.env"
    chmod 0640 "$ENV_DIR/daemon.env"

    {
      printf 'CS_PLUGIN_SOCKET=/run/docker/plugins/%s.sock\n' "$CSS_DRIVER_NAME"
      printf 'CS_DAEMON_SOCKET=/run/cs-storage.sock\n'
      printf 'CS_DOCKER_SOCKET=/var/run/docker.sock\n'
      printf 'CS_PLUGIN_TIMEOUT=120s\n'
      printf 'CS_PLUGIN_SCOPE=local\n'
    } > "$ENV_DIR/plugin.env"
    chown root:"$SERVICE_GROUP" "$ENV_DIR/plugin.env"
    chmod 0640 "$ENV_DIR/plugin.env"
  fi
}

restart_selected() {
  if test "$ENABLE_NOW" != "1"; then
    return
  fi
  if role_has_server; then
    systemctl enable cs-storage-server.service
    if test "$RESTART_SERVICES" = "1"; then
      systemctl restart cs-storage-server.service
    else
      systemctl start cs-storage-server.service
    fi
  fi
  if role_has_client; then
    systemctl enable cs-storage-daemon.service cs-storage-plugin.service
    if test "$RESTART_SERVICES" = "1"; then
      systemctl restart cs-storage-daemon.service
      systemctl restart cs-storage-plugin.service
    else
      systemctl start cs-storage-daemon.service cs-storage-plugin.service
    fi
  elif existing_client_config; then
    systemctl enable cs-storage-daemon.service cs-storage-plugin.service >/dev/null 2>&1 || true
    if test "$RESTART_SERVICES" = "1"; then
      systemctl restart cs-storage-daemon.service cs-storage-plugin.service || true
    else
      systemctl start cs-storage-daemon.service cs-storage-plugin.service || true
    fi
  fi
  if ! role_has_server && existing_server_config; then
    systemctl enable cs-storage-server.service >/dev/null 2>&1 || true
    if test "$RESTART_SERVICES" = "1"; then
      systemctl restart cs-storage-server.service || true
    else
      systemctl start cs-storage-server.service || true
    fi
  fi
}

need_root
validate_inputs
install_deb_package
install_deps
ensure_user_and_dirs
install_binaries
install_units
write_envs
restart_selected

echo "CSS_SYSTEMD_NODE_INSTALL_OK role=$ROLE node=$CS_NODE_ID driver=$CSS_DRIVER_NAME env_dir=$ENV_DIR prefix=$PREFIX"
