#!/bin/sh
set -eu

SMOKE=${1:-}
shift || true
ENV_FILE=${CS_WEBDAV_ENV_FILE:-}
TMP_ENV=${TMP_ENV:-/tmp/cs-storage-webdav.env.$$}

usage() {
  cat <<USAGE
usage: CS_WEBDAV_ENV_FILE=/tmp/cs-storage-webdav.env $0 <smoke-script> [args...]
   or: $0 <smoke-script> [args...] < webdav.env

Allowed smoke scripts:
  ./scripts/hd01-gateway-webdav-smoke.sh
  ./scripts/hd01-host-daemon-webdav-workload-smoke.sh
  ./scripts/hd01-privileged-daemon-webdav-global-smoke.sh
  ./scripts/hd01-shared-multi-sync-webdav-smoke.sh
  ./scripts/hd01-shared-multi-db-sync-webdav-smoke.sh
  ./scripts/hd01-privileged-shared-multi-db-sync-webdav-global-smoke.sh
USAGE
}

case "$SMOKE" in
  ./scripts/hd01-gateway-webdav-smoke.sh|scripts/hd01-gateway-webdav-smoke.sh) SMOKE=./scripts/hd01-gateway-webdav-smoke.sh ;;
  ./scripts/hd01-host-daemon-webdav-workload-smoke.sh|scripts/hd01-host-daemon-webdav-workload-smoke.sh) SMOKE=./scripts/hd01-host-daemon-webdav-workload-smoke.sh ;;
  ./scripts/hd01-privileged-daemon-webdav-global-smoke.sh|scripts/hd01-privileged-daemon-webdav-global-smoke.sh) SMOKE=./scripts/hd01-privileged-daemon-webdav-global-smoke.sh ;;
  ./scripts/hd01-shared-multi-sync-webdav-smoke.sh|scripts/hd01-shared-multi-sync-webdav-smoke.sh) SMOKE=./scripts/hd01-shared-multi-sync-webdav-smoke.sh ;;
  ./scripts/hd01-shared-multi-db-sync-webdav-smoke.sh|scripts/hd01-shared-multi-db-sync-webdav-smoke.sh) SMOKE=./scripts/hd01-shared-multi-db-sync-webdav-smoke.sh ;;
  ./scripts/hd01-privileged-shared-multi-db-sync-webdav-global-smoke.sh|scripts/hd01-privileged-shared-multi-db-sync-webdav-global-smoke.sh) SMOKE=./scripts/hd01-privileged-shared-multi-db-sync-webdav-global-smoke.sh ;;
  ""|-h|--help) usage; exit 0 ;;
  *) echo "WEBDAV_ENV_RUN_REFUSE_SMOKE script=$SMOKE"; usage; exit 1 ;;
esac

validate_env_path() {
  path=$1
  case "$path" in
    /tmp/*|/run/secrets/*|/etc/cs-storage/*) ;;
    *) echo "WEBDAV_ENV_RUN_REFUSE_ENV_PATH path=$path"; exit 1 ;;
  esac
}

cleanup() {
  if test "${created_tmp:-0}" = "1"; then
    rm -f "$TMP_ENV"
  fi
}
trap cleanup EXIT

created_tmp=0
if test -n "$ENV_FILE"; then
  validate_env_path "$ENV_FILE"
  if test ! -r "$ENV_FILE"; then
    echo "WEBDAV_ENV_RUN_ENV_NOT_READABLE path=$ENV_FILE"
    exit 1
  fi
else
  validate_env_path "$TMP_ENV"
  umask 077
  cat > "$TMP_ENV"
  ENV_FILE=$TMP_ENV
  created_tmp=1
fi

for key in CS_WEBDAV_URL CS_WEBDAV_USER CS_WEBDAV_PASSWORD; do
  if ! sed -n "s/^$key=//p" "$ENV_FILE" | tail -n 1 | grep -q .; then
    echo "WEBDAV_ENV_RUN_MISSING_KEY key=$key"
    exit 1
  fi
done

mode=$(stat -c %a "$ENV_FILE" 2>/dev/null || echo unknown)
case "$mode" in
  400|600|0400|0600) ;;
  unknown) echo "WEBDAV_ENV_RUN_WARN stat_failed path=$ENV_FILE" ;;
  *) echo "WEBDAV_ENV_RUN_INSECURE_MODE mode=$mode path=$ENV_FILE"; exit 1 ;;
esac

CS_WEBDAV_ENV_FILE="$ENV_FILE" "$SMOKE" "$@"
