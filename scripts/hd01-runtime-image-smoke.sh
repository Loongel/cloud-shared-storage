#!/bin/sh
set -eu
IMAGE=${IMAGE:-cs-storage:hd01-smoke}
BUILD=${BUILD:-1}
DOCKER_BUILD_ARGS=${DOCKER_BUILD_ARGS:-}
if test "$BUILD" = "1"; then
  # shellcheck disable=SC2086
  docker build $DOCKER_BUILD_ARGS -t "$IMAGE" . >/dev/null
fi
out=$(docker run --rm --entrypoint sh "$IMAGE" -c '
set -eu
for bin in cs-storage-server cs-storage-daemon cs-storage-plugin cs-storage-admin cs-storage-router litefs kopia rclone gocryptfs mount.glusterfs gluster glusterd glusterfsd sqlite3 fusermount3; do
  command -v "$bin" >/dev/null
  printf "%s=%s\n" "$bin" "$(command -v "$bin")"
done
litefs version >/tmp/litefs.version 2>&1 || litefs -version >/tmp/litefs.version 2>&1 || true
kopia --version >/tmp/kopia.version
printf "litefs_version=%s\n" "$(head -n 1 /tmp/litefs.version)"
printf "kopia_version=%s\n" "$(head -n 1 /tmp/kopia.version)"
')
printf '%s\n' "$out"
litefs_version=$(printf '%s\n' "$out" | sed -n 's/^litefs_version=LiteFS \([^,]*\).*/\1/p' | head -n 1)
kopia_version=$(printf '%s\n' "$out" | sed -n 's/^kopia_version=\([^ ]*\).*/\1/p' | head -n 1)
test -n "$litefs_version"
test -n "$kopia_version"
echo "RUNTIME_IMAGE_SMOKE_OK image=$IMAGE litefs=$litefs_version kopia=$kopia_version"
