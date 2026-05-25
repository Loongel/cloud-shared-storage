#!/bin/sh
set -eu

load_common() {
  dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
  if test -f "$dir/css-install-common.sh"; then
    . "$dir/css-install-common.sh"
    return
  fi
  if test -f "$dir/css-install-common"; then
    . "$dir/css-install-common"
    return
  fi
  tmp=$(mktemp /tmp/css-install-common.XXXXXX)
  url=${CSS_COMMON_URL:-https://raw.githubusercontent.com/Loongel/cloud-shared-storage/main/scripts/css-install-common.sh}
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$tmp"
  else
    wget -qO "$tmp" "$url"
  fi
  . "$tmp"
}

load_common
css_install server "$@"
