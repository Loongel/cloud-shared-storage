#!/bin/sh
set -eu

OWNER=${CSS_UPGRADE_OWNER:-Loongel}
REPO=${CSS_UPGRADE_REPO:-cloud-shared-storage}
API_URL=${CSS_UPGRADE_API_URL:-https://api.github.com/repos/$OWNER/$REPO/releases/latest}
LATEST_URL=${CSS_UPGRADE_LATEST_URL:-https://github.com/$OWNER/$REPO/releases/latest}
ASSET_BASE=${CSS_UPGRADE_ASSET_BASE:-https://github.com/$OWNER/$REPO/releases/download}
LOCK_DIR=${CSS_UPGRADE_LOCK_DIR:-/run/cs-storage-upgrade.lock}
LOG_PREFIX=CSS_AUTO_UPGRADE
RETRY_ATTEMPTS=${CSS_UPGRADE_RETRY_ATTEMPTS:-5}
RETRY_DELAY=${CSS_UPGRADE_RETRY_DELAY:-5}
tmp=

log() {
  echo "$LOG_PREFIX $*"
}

retry_sleep() {
  sleep "$RETRY_DELAY"
}

retry_capture_url() {
  url=$1
  i=1
  while :; do
    set +e
    out=$(curl -fsSL "$url" 2>/dev/null)
    rc=$?
    set -e
    if test "$rc" -eq 0; then
      printf '%s' "$out"
      return 0
    fi
    if test "$i" -ge "$RETRY_ATTEMPTS"; then
      return "$rc"
    fi
    log "status=retry op=curl_capture attempt=$i rc=$rc url=$url" >&2
    i=$((i + 1))
    retry_sleep
  done
}

retry_download() {
  url=$1
  dest=$2
  i=1
  while :; do
    set +e
    curl -fsSL "$url" -o "$dest"
    rc=$?
    set -e
    if test "$rc" -eq 0; then
      return 0
    fi
    if test "$i" -ge "$RETRY_ATTEMPTS"; then
      return "$rc"
    fi
    log "status=retry op=curl_download attempt=$i rc=$rc url=$url" >&2
    i=$((i + 1))
    retry_sleep
  done
}

retry_run() {
  op=$1
  shift
  i=1
  while :; do
    set +e
    "$@"
    rc=$?
    set -e
    if test "$rc" -eq 0; then
      return 0
    fi
    if test "$i" -ge "$RETRY_ATTEMPTS"; then
      return "$rc"
    fi
    log "status=retry op=$op attempt=$i rc=$rc" >&2
    i=$((i + 1))
    retry_sleep
  done
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
  retry_capture_url "$API_URL" |
    sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\([^"]*\)".*/\1/p' |
    sed -n '1p'
)
if test -z "$latest"; then
  set +e
  effective_url=$(curl -fsSL -o /dev/null -w '%{url_effective}' "$LATEST_URL" 2>/dev/null)
  rc=$?
  set -e
  if test "$rc" -ne 0; then
    effective_url=""
  fi
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

retry_download "$url" "$deb"
if retry_download "$sumurl" "$sumfile" 2>/dev/null; then
  (cd "$tmp" && sha256sum -c "$(basename "$sumfile")")
fi

export DEBIAN_FRONTEND=noninteractive
export DEBIAN_PRIORITY=critical
export LC_ALL=C
export LANG=C
export LANGUAGE=C
export NEEDRESTART_MODE=a

if command -v apt-get >/dev/null 2>&1; then
  retry_run apt_install apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install -y "$deb"
else
  retry_run dpkg_install dpkg -i "$deb"
fi

log "status=ok action=upgraded from=$installed to=$latest"
