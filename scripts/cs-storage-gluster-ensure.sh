#!/bin/sh
set -eu

ENV_FILE=${1:-/etc/cs-storage/daemon.env}
VOLUME=${CS_GLUSTER_VOLUME:-css_shared}
DEFAULT_BRICK=${CS_GLUSTER_BRICK:-/var/lib/cs-storage/gluster/$VOLUME/brick}

read_env_value() {
  file=$1
  key=$2
  test -f "$file" || return 1
  awk -F= -v k="$key" '$1 == k {sub(/^[^=]*=/, ""); print; found=1; exit} END {exit found ? 0 : 1}' "$file"
}

if test -f "$ENV_FILE"; then
  VOLUME=$(read_env_value "$ENV_FILE" CS_GLUSTER_VOLUME 2>/dev/null || printf '%s' "$VOLUME")
  DEFAULT_BRICK=$(read_env_value "$ENV_FILE" CS_GLUSTER_BRICK 2>/dev/null || printf '%s' "$DEFAULT_BRICK")
fi

command -v gluster >/dev/null 2>&1 || exit 0
if command -v systemctl >/dev/null 2>&1; then
  systemctl start glusterd.service >/dev/null 2>&1 || true
fi

if ! gluster volume info "$VOLUME" >/dev/null 2>&1; then
  exit 0
fi

brick_paths=$(gluster volume info "$VOLUME" 2>/dev/null | awk '
  /^Brick[0-9]+:/ {
    sub(/^Brick[0-9]+:[[:space:]]*/, "")
    sub(/^[^:]*:/, "")
    print
  }
')
if test -z "$brick_paths"; then
  brick_paths=$DEFAULT_BRICK
fi

printf '%s\n' "$brick_paths" | while IFS= read -r brick; do
  test -n "$brick" || continue
  if test -d "$brick" || test "$brick" = "$DEFAULT_BRICK"; then
    install -d -m 0755 "$brick/.glusterfs/indices"
  fi
done

gluster volume start "$VOLUME" force >/dev/null 2>&1 || true
