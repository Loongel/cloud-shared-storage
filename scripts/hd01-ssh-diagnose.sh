#!/bin/sh
set -eu

HD01_HOST=${HD01_HOST:-108.62.161.204}
HD01_PORT=${HD01_PORT:-16022}
HD01_USER=${HD01_USER:-root}
HD01_IDENTITY=${HD01_IDENTITY:-}
HD01_ASKPASS_FILE=${HD01_ASKPASS_FILE:-}
JUMP_HOST=${JUMP_HOST:-}
JUMP_PORT=${JUMP_PORT:-16022}
CONNECT_TIMEOUT=${CONNECT_TIMEOUT:-8}
SSH_TIMEOUT=${SSH_TIMEOUT:-20}

identity_args=""
if test -n "$HD01_IDENTITY"; then
  identity_args="-i $HD01_IDENTITY"
fi

ASKPASS_DIR=""
ASKPASS_HELPER=""
if test -n "$HD01_ASKPASS_FILE"; then
  if ! test -r "$HD01_ASKPASS_FILE"; then
    echo "SSH_DIAG_ERROR askpass_file_unreadable=$HD01_ASKPASS_FILE"
    exit 1
  fi
  ASKPASS_DIR=$(mktemp -d /tmp/cs-storage-ssh-askpass.XXXXXX)
  ASKPASS_HELPER=$ASKPASS_DIR/askpass
  printf '%s\n' '#!/bin/sh' 'cat "$CS_STORAGE_ASKPASS_FILE"' >"$ASKPASS_HELPER"
  chmod 700 "$ASKPASS_HELPER"
fi

cleanup() {
  if test -n "$ASKPASS_DIR"; then
    rm -rf "$ASKPASS_DIR"
  fi
}
trap cleanup EXIT

run_ssh() {
  if test -n "$HD01_ASKPASS_FILE"; then
    timeout "$SSH_TIMEOUT" setsid env -u SSH_AUTH_SOCK DISPLAY=:0 SSH_ASKPASS="$ASKPASS_HELPER" SSH_ASKPASS_REQUIRE=force CS_STORAGE_ASKPASS_FILE="$HD01_ASKPASS_FILE" ssh -o BatchMode=no "$@"
  else
    timeout "$SSH_TIMEOUT" ssh -o BatchMode=yes "$@"
  fi
}

run_nc() {
  echo "SSH_DIAG_TCP host=$HD01_HOST port=$HD01_PORT"
  if timeout "$CONNECT_TIMEOUT" nc -vz "$HD01_HOST" "$HD01_PORT"; then
    echo "SSH_DIAG_TCP_OK host=$HD01_HOST port=$HD01_PORT"
  else
    echo "SSH_DIAG_TCP_FAIL host=$HD01_HOST port=$HD01_PORT"
  fi
  echo "SSH_DIAG_BANNER host=$HD01_HOST port=$HD01_PORT"
  timeout "$CONNECT_TIMEOUT" sh -c 'nc -v "$1" "$2" </dev/null' sh "$HD01_HOST" "$HD01_PORT" 2>&1 | sed -n '1,3p' || true
}

try_ssh() {
  name=$1
  shift
  err=/tmp/cs-storage-ssh-diagnose.$$.err
  out=/tmp/cs-storage-ssh-diagnose.$$.out
  echo "SSH_DIAG_TRY name=$name"
  # shellcheck disable=SC2086
  if run_ssh -o ProxyCommand=none -o ConnectTimeout="$CONNECT_TIMEOUT" -o ServerAliveInterval=5 -o ServerAliveCountMax=1 -o IdentitiesOnly=yes $identity_args -p "$HD01_PORT" -o StrictHostKeyChecking=accept-new "$@" "$HD01_USER@$HD01_HOST" 'echo SSH_OK' >"$out" 2>"$err"; then
    printf 'SSH_DIAG_OK name=%s output=' "$name"
    cat "$out"
  else
    rc=$?
    last=$(tail -n 1 "$err" 2>/dev/null || true)
    printf 'SSH_DIAG_FAIL name=%s rc=%s last=%s\n' "$name" "$rc" "$last"
  fi
  rm -f "$out" "$err"
}

run_jump_banner() {
  if test -z "$JUMP_HOST"; then
    return
  fi
  echo "SSH_DIAG_JUMP_TCP jump=$JUMP_HOST:$JUMP_PORT target=$HD01_HOST:$HD01_PORT"
  err=/tmp/cs-storage-ssh-diagnose.jump.$$.err
  # shellcheck disable=SC2086
  run_ssh -o ConnectTimeout="$CONNECT_TIMEOUT" -o ServerAliveInterval=5 -o ServerAliveCountMax=1 -o IdentitiesOnly=yes $identity_args -p "$JUMP_PORT" -o StrictHostKeyChecking=accept-new "$HD01_USER@$JUMP_HOST" "timeout $CONNECT_TIMEOUT nc -vz $HD01_HOST $HD01_PORT" 2>"$err" || true
  sed -n '1,5p' "$err" || true
  rm -f "$err"
}

run_nc
try_ssh default
try_ssh curve25519 -o KexAlgorithms=curve25519-sha256
try_ssh ecdh-nistp256 -o KexAlgorithms=ecdh-sha2-nistp256
try_ssh no-ipqos -o IPQoS=none -o KexAlgorithms=ecdh-sha2-nistp256
run_jump_banner
