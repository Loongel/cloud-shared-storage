#!/bin/sh
set -eu

OWNER=${CSS_UPGRADE_OWNER:-Loongel}
REPO=${CSS_UPGRADE_REPO:-cloud-shared-storage}
API_URL=${CSS_UPGRADE_API_URL:-https://api.github.com/repos/$OWNER/$REPO/releases/latest}
LATEST_URL=${CSS_UPGRADE_LATEST_URL:-https://github.com/$OWNER/$REPO/releases/latest}
ASSET_BASE=${CSS_UPGRADE_ASSET_BASE:-https://github.com/$OWNER/$REPO/releases/download}
LOCK_DIR=${CSS_UPGRADE_LOCK_DIR:-/run/cs-storage-upgrade.lock}
LOG_PREFIX=CSS_AUTO_UPGRADE
tmp=

log() {
  echo "$LOG_PREFIX $*"
}

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  log "status=skip reason=lock_held"
  exit 0
fi
cleanup() {
  rmdir "$LOCK_DIR" >/dev/null 2>&1 || true
  if test -n "$tmp"; then
    rm -rf "$tmp" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

command -v dpkg-query >/dev/null 2>&1 || { log "status=skip reason=missing_dpkg_query"; exit 0; }
command -v curl >/dev/null 2>&1 || { log "status=skip reason=missing_curl"; exit 0; }

installed=$(dpkg-query -W -f='${Version}' cs-storage 2>/dev/null || true)
if test -z "$installed"; then
  log "status=skip reason=package_not_installed"
  exit 0
fi

latest=$(
  curl -fsSL "$API_URL" 2>/dev/null |
    sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\([^"]*\)".*/\1/p' |
    sed -n '1p'
)
if test -z "$latest"; then
  effective_url=$(curl -fsSL -o /dev/null -w '%{url_effective}' "$LATEST_URL" 2>/dev/null || true)
  latest=$(printf '%s\n' "$effective_url" | sed -n 's#.*/releases/tag/v\([^/?#]*\).*#\1#p' | sed -n '1p')
fi
if test -z "$latest"; then
  log "status=skip reason=latest_version_unavailable installed=$installed"
  exit 0
fi

if ! dpkg --compare-versions "$latest" gt "$installed"; then
  log "status=ok action=none installed=$installed latest=$latest"
  exit 0
fi

tmp=$(mktemp -d /tmp/cs-storage-auto-upgrade.XXXXXX)
deb="$tmp/cs-storage_${latest}_amd64.deb"
sumfile="$deb.sha256"
url="$ASSET_BASE/v$latest/cs-storage_${latest}_amd64.deb"
sumurl="$url.sha256"

curl -fsSL "$url" -o "$deb"
if curl -fsSL "$sumurl" -o "$sumfile" 2>/dev/null; then
  (cd "$tmp" && sha256sum -c "$(basename "$sumfile")")
fi

active_services=
for svc in cs-storage-server.service cs-storage-daemon.service cs-storage-plugin.service; do
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    active_services="$active_services $svc"
  fi
done

export DEBIAN_FRONTEND=noninteractive
export DEBIAN_PRIORITY=critical
export LC_ALL=C
export LANG=C
export LANGUAGE=C
export NEEDRESTART_MODE=a

if command -v apt-get >/dev/null 2>&1; then
  apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install -y "$deb"
else
  dpkg -i "$deb"
fi

if test -n "$active_services"; then
  # shellcheck disable=SC2086
  systemctl try-restart $active_services
fi

log "status=ok action=upgraded from=$installed to=$latest"
