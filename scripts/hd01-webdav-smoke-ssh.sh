#!/bin/sh
set -eu

SMOKE=${1:-}
if test "$#" -gt 0; then
  shift
fi
if test "$#" -ne 0; then
  echo "HD01_WEBDAV_SSH_REFUSE_ARGS count=$#"
  exit 1
fi

HD01_HOST=${HD01_HOST:-108.62.161.204}
HD01_PORT=${HD01_PORT:-16022}
HD01_USER=${HD01_USER:-root}
HD01_WORKDIR=${HD01_WORKDIR:-/tmp/cs-storage-work-current}
HD01_IDENTITY=${HD01_IDENTITY:-}
HD01_ASKPASS_FILE=${HD01_ASKPASS_FILE:-}
CONNECT_TIMEOUT=${CONNECT_TIMEOUT:-30}
SERVER_ALIVE_INTERVAL=${SERVER_ALIVE_INTERVAL:-10}
SERVER_ALIVE_COUNT_MAX=${SERVER_ALIVE_COUNT_MAX:-5}

usage() {
  cat <<USAGE
usage: $0 <webdav-smoke-script> < webdav.env

Before running, sync current source to hd01 /tmp/cs-storage-work-current.
Set HD01_IDENTITY and optionally HD01_ASKPASS_FILE for non-interactive SSH.

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
  *) echo "HD01_WEBDAV_SSH_REFUSE_SMOKE script=$SMOKE"; usage; exit 1 ;;
esac

case "$HD01_WORKDIR" in
  /tmp/cs-storage-work*) ;;
  *) echo "HD01_WEBDAV_SSH_REFUSE_WORKDIR path=$HD01_WORKDIR"; exit 1 ;;
esac

if test -t 0; then
  echo "HD01_WEBDAV_SSH_STDIN_REQUIRED"
  exit 1
fi

identity_args=""
if test -n "$HD01_IDENTITY"; then
  identity_args="-i $HD01_IDENTITY"
fi

ASKPASS_DIR=""
ASKPASS_HELPER=""
if test -n "$HD01_ASKPASS_FILE"; then
  if ! test -r "$HD01_ASKPASS_FILE"; then
    echo "HD01_WEBDAV_SSH_ASKPASS_UNREADABLE path=$HD01_ASKPASS_FILE"
    exit 1
  fi
  ASKPASS_DIR=$(mktemp -d /tmp/cs-storage-ssh-askpass.XXXXXX)
  ASKPASS_HELPER=$ASKPASS_DIR/askpass
  printf '%s\n' '#!/bin/sh' 'cat "$CS_STORAGE_ASKPASS_FILE"' > "$ASKPASS_HELPER"
  chmod 700 "$ASKPASS_HELPER"
fi

cleanup() {
  if test -n "$ASKPASS_DIR"; then
    rm -rf "$ASKPASS_DIR"
  fi
}
trap cleanup EXIT

remote_cmd="cd $HD01_WORKDIR && ./scripts/hd01-webdav-env-run.sh $SMOKE"

if test -n "$HD01_ASKPASS_FILE"; then
  # shellcheck disable=SC2086
  setsid env -u SSH_AUTH_SOCK DISPLAY=:0 SSH_ASKPASS="$ASKPASS_HELPER" SSH_ASKPASS_REQUIRE=force CS_STORAGE_ASKPASS_FILE="$HD01_ASKPASS_FILE" \
    ssh -o BatchMode=no -o ProxyCommand=none -o ConnectTimeout="$CONNECT_TIMEOUT" -o ServerAliveInterval="$SERVER_ALIVE_INTERVAL" -o ServerAliveCountMax="$SERVER_ALIVE_COUNT_MAX" -o IdentitiesOnly=yes $identity_args -p "$HD01_PORT" -o StrictHostKeyChecking=accept-new "$HD01_USER@$HD01_HOST" "$remote_cmd"
else
  # shellcheck disable=SC2086
  ssh -o BatchMode=yes -o ProxyCommand=none -o ConnectTimeout="$CONNECT_TIMEOUT" -o ServerAliveInterval="$SERVER_ALIVE_INTERVAL" -o ServerAliveCountMax="$SERVER_ALIVE_COUNT_MAX" -o IdentitiesOnly=yes $identity_args -p "$HD01_PORT" -o StrictHostKeyChecking=accept-new "$HD01_USER@$HD01_HOST" "$remote_cmd"
fi
