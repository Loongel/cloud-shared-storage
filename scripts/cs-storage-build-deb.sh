#!/bin/sh
set -eu

VERSION=${VERSION:-0.1.5}
ARCH=${ARCH:-}
OUT_DIR=${OUT_DIR:-dist}
BIN_DIR=${BIN_DIR:-bin}
BUILD_BINARIES=${BUILD_BINARIES:-auto}
DEB_COMPRESSION=${DEB_COMPRESSION:-xz}
INCLUDE_RUNTIME_TOOLS=${INCLUDE_RUNTIME_TOOLS:-1}
LITEFS_IMAGE=${LITEFS_IMAGE:-flyio/litefs:0.5}
KOPIA_IMAGE=${KOPIA_IMAGE:-kopia/kopia:0.23}
PACKAGE=cs-storage
MAINTAINER=${MAINTAINER:-CS-Storage Maintainers <root@localhost>}

usage() {
  cat <<'EOF'
Usage: scripts/cs-storage-build-deb.sh [options]

Build a Debian package containing CS-Storage host-service artifacts.

Options:
  --version VERSION       Package version, default 0.1.5.
  --arch ARCH             Debian architecture, default dpkg --print-architecture.
  --out-dir DIR           Output directory, default dist.
  --bin-dir DIR           Prebuilt binary directory, default bin.
  --compression FORMAT    dpkg-deb compression, default xz.
  --build-binaries        Always rebuild Go binaries before packaging.
  --no-build-binaries     Require existing binaries in --bin-dir.
  --runtime-tools         Require and bundle litefs/kopia, default.
  --no-runtime-tools      Do not bundle litefs/kopia; development packages only.

Environment:
  VERSION, ARCH, OUT_DIR, BIN_DIR, BUILD_BINARIES, DEB_COMPRESSION,
  INCLUDE_RUNTIME_TOOLS, LITEFS_IMAGE, KOPIA_IMAGE, MAINTAINER.

The package installs:
  /usr/local/bin/cs-storage-*
  /lib/systemd/system/cs-storage-*.service
  /usr/local/sbin/cs-storage-systemd-node-install
  /usr/local/sbin/css-install-{server,client,all}
  /usr/share/cs-storage/env/*.example
EOF
}

while test "$#" -gt 0; do
  case "$1" in
    --version) shift; VERSION=$1 ;;
    --arch) shift; ARCH=$1 ;;
    --out-dir) shift; OUT_DIR=$1 ;;
    --bin-dir) shift; BIN_DIR=$1 ;;
    --compression) shift; DEB_COMPRESSION=$1 ;;
    --build-binaries) BUILD_BINARIES=1 ;;
    --no-build-binaries) BUILD_BINARIES=0 ;;
    --runtime-tools) INCLUDE_RUNTIME_TOOLS=1 ;;
    --no-runtime-tools) INCLUDE_RUNTIME_TOOLS=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

if test -z "$ARCH"; then
  if command -v dpkg >/dev/null 2>&1; then
    ARCH=$(dpkg --print-architecture)
  else
    ARCH=amd64
  fi
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing command: $1" >&2; exit 1; }
}

all_bins_present() {
  for bin in cs-storage-server cs-storage-daemon cs-storage-plugin cs-storage-admin cs-storage-router; do
    test -x "$BIN_DIR/$bin" || return 1
  done
}

build_binaries() {
  mkdir -p "$BIN_DIR"
  if command -v go >/dev/null 2>&1; then
    go test ./...
    go build -buildvcs=false -o "$BIN_DIR/cs-storage-server" ./cmd/cs-storage-server
    go build -buildvcs=false -o "$BIN_DIR/cs-storage-daemon" ./cmd/cs-storage-daemon
    go build -buildvcs=false -o "$BIN_DIR/cs-storage-plugin" ./cmd/cs-storage-plugin
    go build -buildvcs=false -o "$BIN_DIR/cs-storage-admin" ./cmd/cs-storage-admin
    go build -buildvcs=false -o "$BIN_DIR/cs-storage-router" ./cmd/cs-storage-router
    return
  fi
  need_cmd docker
  docker run --rm --network host -v "$ROOT:/src" -w /src golang:1.22-bookworm sh -lc '
    set -eu
    mkdir -p "$0"
    go test ./...
    go build -buildvcs=false -o "$0/cs-storage-server" ./cmd/cs-storage-server
    go build -buildvcs=false -o "$0/cs-storage-daemon" ./cmd/cs-storage-daemon
    go build -buildvcs=false -o "$0/cs-storage-plugin" ./cmd/cs-storage-plugin
    go build -buildvcs=false -o "$0/cs-storage-admin" ./cmd/cs-storage-admin
    go build -buildvcs=false -o "$0/cs-storage-router" ./cmd/cs-storage-router
  ' "$BIN_DIR"
}

copy_runtime_tool_from_image() {
  tool=$1
  image=$2
  shift 2
  need_cmd docker
  docker pull "$image" >/dev/null
  cid=$(docker create "$image")
  tmp=$(mktemp -d /tmp/cs-storage-runtime-tool.XXXXXX)
  cleanup_runtime_tool() {
    docker rm "$cid" >/dev/null 2>&1 || true
    rm -rf "$tmp"
  }
  trap cleanup_runtime_tool EXIT INT TERM
  for candidate in "$@"; do
    if docker cp "$cid:$candidate" "$tmp/$tool" >/dev/null 2>&1; then
      install -m 0755 "$tmp/$tool" "$BIN_DIR/$tool"
      trap - EXIT INT TERM
      cleanup_runtime_tool
      return
    fi
  done
  echo "failed to extract $tool from $image" >&2
  exit 1
}

ensure_runtime_tools() {
  if test "$INCLUDE_RUNTIME_TOOLS" != "1"; then
    return
  fi
  mkdir -p "$BIN_DIR"
  if test ! -x "$BIN_DIR/litefs"; then
    copy_runtime_tool_from_image litefs "$LITEFS_IMAGE" /usr/local/bin/litefs /usr/bin/litefs /bin/litefs
  fi
  if test ! -x "$BIN_DIR/kopia"; then
    copy_runtime_tool_from_image kopia "$KOPIA_IMAGE" /usr/local/bin/kopia /usr/bin/kopia /bin/kopia
  fi
}

case "$BUILD_BINARIES" in
  1) build_binaries ;;
  0) all_bins_present || { echo "missing cs-storage binaries in $BIN_DIR" >&2; exit 1; } ;;
  auto)
    if ! all_bins_present; then
      build_binaries
    fi
    ;;
  *) echo "invalid BUILD_BINARIES=$BUILD_BINARIES" >&2; exit 1 ;;
esac

ensure_runtime_tools

need_cmd dpkg-deb

pkg_root=$(mktemp -d /tmp/cs-storage-deb-root.XXXXXX)
trap 'rm -rf "$pkg_root"' EXIT INT TERM
chmod 0755 "$pkg_root"

install -d -m 0755 \
  "$pkg_root/DEBIAN" \
  "$pkg_root/usr/local/bin" \
  "$pkg_root/usr/local/sbin" \
  "$pkg_root/usr/share/cs-storage/env" \
  "$pkg_root/lib/systemd/system" \
  "$pkg_root/etc/cs-storage/secrets" \
  "$pkg_root/var/lib/cs-storage" \
  "$pkg_root/var/log/cs-storage"

for bin in cs-storage-server cs-storage-daemon cs-storage-plugin cs-storage-admin cs-storage-router; do
  install -m 0755 "$BIN_DIR/$bin" "$pkg_root/usr/local/bin/$bin"
done
for bin in litefs kopia; do
  if test -x "$BIN_DIR/$bin"; then
    install -m 0755 "$BIN_DIR/$bin" "$pkg_root/usr/local/bin/$bin"
  fi
done

install -m 0755 scripts/cs-storage-systemd-node-install.sh "$pkg_root/usr/local/sbin/cs-storage-systemd-node-install"
install -m 0755 scripts/cs-storage-firewall-ensure.sh "$pkg_root/usr/local/sbin/cs-storage-firewall-ensure"
install -m 0755 scripts/css-install-common.sh "$pkg_root/usr/local/sbin/css-install-common"
install -m 0755 scripts/css-install-server.sh "$pkg_root/usr/local/sbin/css-install-server"
install -m 0755 scripts/css-install-client.sh "$pkg_root/usr/local/sbin/css-install-client"
install -m 0755 scripts/css-install-all.sh "$pkg_root/usr/local/sbin/css-install-all"
for unit in cs-storage-server.service cs-storage-daemon.service cs-storage-plugin.service; do
  install -m 0644 "deploy/systemd/$unit" "$pkg_root/lib/systemd/system/$unit"
done
for env in server.env daemon.env plugin.env; do
  install -m 0644 "deploy/env/$env.example" "$pkg_root/usr/share/cs-storage/env/$env.example"
done

cat > "$pkg_root/DEBIAN/control" <<EOF
Package: $PACKAGE
Version: $VERSION
Section: admin
Priority: optional
Architecture: $ARCH
Maintainer: $MAINTAINER
Depends: ca-certificates, fuse3, rclone, gocryptfs, glusterfs-client, glusterfs-server, sqlite3
Description: CS-Storage host systemd services and Docker volume driver
 CS-Storage provides a systemd-managed S-side gateway, C-side daemon,
 and Docker VolumeDriver thin proxy for network-backed Docker volumes.
EOF

cat > "$pkg_root/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -eu
if command -v getent >/dev/null 2>&1 && ! getent group cs-storage >/dev/null 2>&1; then
  groupadd --system cs-storage || true
fi
if ! id -u cs-storage >/dev/null 2>&1; then
  useradd --system --gid cs-storage --home-dir /var/lib/cs-storage --shell /usr/sbin/nologin cs-storage || true
fi
install -d -m 0750 -o root -g cs-storage /etc/cs-storage
install -d -m 0750 -o root -g cs-storage /etc/cs-storage/secrets
chown root:cs-storage /etc/cs-storage /etc/cs-storage/secrets || true
chmod 0750 /etc/cs-storage /etc/cs-storage/secrets || true
install -d -m 0755 /var/lib/cs-storage /var/log/cs-storage /run/docker/plugins
chown cs-storage:cs-storage /var/lib/cs-storage /var/log/cs-storage || true
if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload || true
fi
EOF
chmod 0755 "$pkg_root/DEBIAN/postinst"

cat > "$pkg_root/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -eu
if test "${1:-}" = remove && command -v systemctl >/dev/null 2>&1; then
  systemctl stop cs-storage-plugin.service cs-storage-daemon.service cs-storage-server.service >/dev/null 2>&1 || true
  systemctl disable cs-storage-plugin.service cs-storage-daemon.service cs-storage-server.service >/dev/null 2>&1 || true
fi
EOF
chmod 0755 "$pkg_root/DEBIAN/prerm"

cat > "$pkg_root/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -eu
if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed cs-storage-plugin.service cs-storage-daemon.service cs-storage-server.service >/dev/null 2>&1 || true
fi
if test "${1:-}" = purge; then
  if command -v chattr >/dev/null 2>&1 && test -d /mnt/cs_storage; then
    chattr -R -i /mnt/cs_storage >/dev/null 2>&1 || true
  fi
  if test -d /mnt/cs_storage && command -v find >/dev/null 2>&1; then
    find /mnt/cs_storage -depth -type d -name mount -exec umount -l {} \; >/dev/null 2>&1 || true
  fi
  rm -rf /etc/cs-storage /var/lib/cs-storage /var/log/cs-storage /mnt/cs_storage
  rm -f /run/cs-storage.sock /run/docker/plugins/css.sock
  if command -v userdel >/dev/null 2>&1 && id -u cs-storage >/dev/null 2>&1; then
    userdel cs-storage >/dev/null 2>&1 || true
  fi
  if command -v groupdel >/dev/null 2>&1 && getent group cs-storage >/dev/null 2>&1; then
    groupdel cs-storage >/dev/null 2>&1 || true
  fi
fi
EOF
chmod 0755 "$pkg_root/DEBIAN/postrm"

mkdir -p "$OUT_DIR"
deb="$OUT_DIR/${PACKAGE}_${VERSION}_${ARCH}.deb"
dpkg-deb --root-owner-group -Z"$DEB_COMPRESSION" --build "$pkg_root" "$deb"
echo "CS_STORAGE_DEB_BUILT path=$deb"
