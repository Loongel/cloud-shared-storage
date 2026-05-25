#!/bin/sh
set -eu

PREFIX=${PREFIX:-/usr/local/bin}
SYSTEMD_DIR=${SYSTEMD_DIR:-/etc/systemd/system}
ENV_DIR=${ENV_DIR:-/etc/cs-storage}
STATE_DIR=${STATE_DIR:-/var/lib/cs-storage}
LOG_DIR=${LOG_DIR:-/var/log/cs-storage}
SRC_DIR=${SRC_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}
INSTALL_BIN=${INSTALL_BIN:-install}
SERVICE_USER=${SERVICE_USER:-cs-storage}
SERVICE_GROUP=${SERVICE_GROUP:-$SERVICE_USER}
CREATE_SERVICE_USER=${CREATE_SERVICE_USER:-1}
RELOAD_SYSTEMD=${RELOAD_SYSTEMD:-1}

ensure_service_user() {
  if test "$CREATE_SERVICE_USER" != "1"; then
    return
  fi
  if id -u "$SERVICE_USER" >/dev/null 2>&1; then
    return
  fi
  if test "$(id -u)" != "0"; then
    echo "service user $SERVICE_USER is missing; rerun as root or set CREATE_SERVICE_USER=0 for staged installs" >&2
    exit 1
  fi
  if command -v getent >/dev/null 2>&1 && ! getent group "$SERVICE_GROUP" >/dev/null 2>&1; then
    if command -v groupadd >/dev/null 2>&1; then
      groupadd --system "$SERVICE_GROUP"
    fi
  fi
  if command -v useradd >/dev/null 2>&1; then
    useradd --system --gid "$SERVICE_GROUP" --home-dir "$STATE_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"
  elif command -v adduser >/dev/null 2>&1; then
    adduser --system --ingroup "$SERVICE_GROUP" --home "$STATE_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"
  else
    echo "cannot create service user $SERVICE_USER: useradd/adduser not found" >&2
    exit 1
  fi
}

ensure_service_user

$INSTALL_BIN -d -m 0755 "$PREFIX" "$SYSTEMD_DIR" "$ENV_DIR" "$STATE_DIR" "$LOG_DIR"
if id -u "$SERVICE_USER" >/dev/null 2>&1; then
  chown "$SERVICE_USER:$SERVICE_GROUP" "$STATE_DIR" "$LOG_DIR"
fi

for bin in cs-storage-server cs-storage-daemon cs-storage-plugin cs-storage-admin cs-storage-router; do
  if test ! -x "$SRC_DIR/bin/$bin"; then
    echo "missing executable $SRC_DIR/bin/$bin" >&2
    exit 1
  fi
  $INSTALL_BIN -m 0755 "$SRC_DIR/bin/$bin" "$PREFIX/$bin"
done
for unit in cs-storage-server.service cs-storage-daemon.service cs-storage-plugin.service; do
  $INSTALL_BIN -m 0644 "$SRC_DIR/deploy/systemd/$unit" "$SYSTEMD_DIR/$unit"
done
for env in server.env daemon.env plugin.env; do
  if test ! -f "$ENV_DIR/$env"; then
    $INSTALL_BIN -m 0600 "$SRC_DIR/deploy/env/$env.example" "$ENV_DIR/$env"
  fi
done
if test "$RELOAD_SYSTEMD" = "1" && command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload
fi
echo "CS-Storage installed. Edit $ENV_DIR/*.env, then enable/start the needed services."
