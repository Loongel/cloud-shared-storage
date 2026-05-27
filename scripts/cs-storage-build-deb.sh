#!/bin/sh
set -eu

VERSION=${VERSION:-0.1.21}
ARCH=${ARCH:-}
OUT_DIR=${OUT_DIR:-dist}
BIN_DIR=${BIN_DIR:-bin}
BUILD_BINARIES=${BUILD_BINARIES:-1}
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
  --version VERSION       Package version, default 0.1.21.
  --arch ARCH             Debian architecture, default dpkg --print-architecture.
  --out-dir DIR           Output directory, default dist.
  --bin-dir DIR           Prebuilt binary directory, default bin.
  --compression FORMAT    dpkg-deb compression, default xz.
  --build-binaries        Always rebuild Go binaries before packaging, default.
  --no-build-binaries     Require existing binaries in --bin-dir.
  --runtime-tools         Require and bundle litefs/kopia, default.
  --no-runtime-tools      Do not bundle litefs/kopia; development packages only.

Environment:
  VERSION, ARCH, OUT_DIR, BIN_DIR, BUILD_BINARIES, DEB_COMPRESSION,
  INCLUDE_RUNTIME_TOOLS, LITEFS_IMAGE, KOPIA_IMAGE, MAINTAINER.

The package installs:
  /usr/lib/cs-storage/bin/cs-storage-*
  /usr/bin/cs-storage-* symlinks
  /lib/systemd/system/cs-storage-*.service
  /usr/lib/cs-storage/sbin/*
  /usr/sbin/css-install-{server,client,all} symlinks
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
    CGO_ENABLED=0 go test ./...
    CGO_ENABLED=0 go build -buildvcs=false -o "$BIN_DIR/cs-storage-server" ./cmd/cs-storage-server
    CGO_ENABLED=0 go build -buildvcs=false -o "$BIN_DIR/cs-storage-daemon" ./cmd/cs-storage-daemon
    CGO_ENABLED=0 go build -buildvcs=false -o "$BIN_DIR/cs-storage-plugin" ./cmd/cs-storage-plugin
    CGO_ENABLED=0 go build -buildvcs=false -o "$BIN_DIR/cs-storage-admin" ./cmd/cs-storage-admin
    CGO_ENABLED=0 go build -buildvcs=false -o "$BIN_DIR/cs-storage-router" ./cmd/cs-storage-router
    return
  fi
  need_cmd docker
  docker run --rm --network host -v "$ROOT:/src" -w /src golang:1.22-bookworm sh -c '
    set -eu
    export PATH=/usr/local/go/bin:/go/bin:$PATH
    export CGO_ENABLED=0
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
  "$pkg_root/usr/bin" \
  "$pkg_root/usr/sbin" \
  "$pkg_root/usr/lib/cs-storage/bin" \
  "$pkg_root/usr/lib/cs-storage/sbin" \
  "$pkg_root/usr/share/cs-storage/env" \
  "$pkg_root/lib/systemd/system" \
  "$pkg_root/etc/cs-storage/secrets" \
  "$pkg_root/var/lib/cs-storage" \
  "$pkg_root/var/log/cs-storage"

for bin in cs-storage-server cs-storage-daemon cs-storage-plugin cs-storage-admin cs-storage-router; do
  install -m 0755 "$BIN_DIR/$bin" "$pkg_root/usr/lib/cs-storage/bin/$bin"
  ln -s "../lib/cs-storage/bin/$bin" "$pkg_root/usr/bin/$bin"
done
for bin in litefs kopia; do
  if test -x "$BIN_DIR/$bin"; then
    install -m 0755 "$BIN_DIR/$bin" "$pkg_root/usr/lib/cs-storage/bin/$bin"
  fi
done

install -m 0755 scripts/cs-storage-systemd-node-install.sh "$pkg_root/usr/lib/cs-storage/sbin/cs-storage-systemd-node-install"
install -m 0755 scripts/cs-storage-firewall-ensure.sh "$pkg_root/usr/lib/cs-storage/sbin/cs-storage-firewall-ensure"
install -m 0755 scripts/cs-storage-auto-upgrade.sh "$pkg_root/usr/lib/cs-storage/sbin/cs-storage-auto-upgrade"
install -m 0755 scripts/css-install-common.sh "$pkg_root/usr/lib/cs-storage/sbin/css-install-common"
install -m 0755 scripts/css-install-server.sh "$pkg_root/usr/lib/cs-storage/sbin/css-install-server"
install -m 0755 scripts/css-install-client.sh "$pkg_root/usr/lib/cs-storage/sbin/css-install-client"
install -m 0755 scripts/css-install-all.sh "$pkg_root/usr/lib/cs-storage/sbin/css-install-all"
for sbin in cs-storage-systemd-node-install cs-storage-firewall-ensure css-install-server css-install-client css-install-all; do
  ln -s "../lib/cs-storage/sbin/$sbin" "$pkg_root/usr/sbin/$sbin"
done
for unit in cs-storage-server.service cs-storage-daemon.service cs-storage-plugin.service cs-storage-auto-upgrade.service cs-storage-auto-upgrade.timer; do
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
cleanup_legacy_units() {
  ts=$(date +%Y%m%d-%H%M%S)
  for unit in cs-storage-server.service cs-storage-daemon.service cs-storage-plugin.service; do
    path="/etc/systemd/system/$unit"
    if test -f "$path" && grep -Eq '/usr/local/(bin|sbin)/cs-storage' "$path"; then
      mv "$path" "$path.BAK.$ts"
      echo "CSS_POSTINST_LEGACY_UNIT_BACKED_UP path=$path backup=$path.BAK.$ts" >&2
    fi
  done
}
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
rm -f \
  /run/docker/plugins/cs-storage.sock \
  /etc/docker/plugins/cs-storage.spec \
  /etc/docker/plugins/cs-storage.json
rm -f \
  /usr/local/bin/cs-storage-server \
  /usr/local/bin/cs-storage-daemon \
  /usr/local/bin/cs-storage-plugin \
  /usr/local/bin/cs-storage-admin \
  /usr/local/bin/cs-storage-router \
  /usr/local/sbin/cs-storage-systemd-node-install \
  /usr/local/sbin/cs-storage-firewall-ensure \
  /usr/local/sbin/css-install-common \
  /usr/local/sbin/css-install-server \
  /usr/local/sbin/css-install-client \
  /usr/local/sbin/css-install-all
chown cs-storage:cs-storage /var/lib/cs-storage /var/log/cs-storage || true
if command -v systemctl >/dev/null 2>&1; then
  cleanup_legacy_units
  systemctl daemon-reload || true
  systemctl enable --now cs-storage-auto-upgrade.timer >/dev/null 2>&1 || true
  systemctl try-restart cs-storage-server.service cs-storage-daemon.service cs-storage-plugin.service >/dev/null 2>&1 || true
fi
EOF
chmod 0755 "$pkg_root/DEBIAN/postinst"

cat > "$pkg_root/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -eu
force_remove() {
  test "${CSS_STORAGE_PURGE_FORCE:-}" = "1" || test "${CSS_FORCE_PURGE:-}" = "1"
}
docker_cmd() {
  command -v docker >/dev/null 2>&1 || return 127
  docker "$@"
}
fail_if_css_in_use() {
  force_remove && return 0
  issues=""
  if docker_cmd info >/dev/null 2>&1; then
    vols=$(docker_cmd volume ls --format '{{.Driver}}\t{{.Name}}' 2>/dev/null | awk -F '\t' '$1 == "css" {print $2}' | tr '\n' ' ' || true)
    if test -n "$vols"; then
      issues="${issues} css_volumes=[$vols]"
      for vol in $vols; do
        containers=$(docker_cmd ps -a --filter "volume=$vol" --format '{{.Names}}' 2>/dev/null | tr '\n' ' ' || true)
        test -z "$containers" || issues="${issues} volume_$vol containers=[$containers]"
      done
    fi
  fi
  if command -v findmnt >/dev/null 2>&1 && findmnt -R /mnt/cs_storage/vols >/dev/null 2>&1; then
    mounts=$(findmnt -R /mnt/cs_storage/vols -n -o TARGET 2>/dev/null | tr '\n' ' ' || true)
    issues="${issues} active_mounts=[$mounts]"
  fi
  if test -n "$issues"; then
    cat >&2 <<EOM
CSS_PURGE_BLOCKED: CSS storage is still in use.$issues
Stop/remove stacks or containers using driver 'css', remove CSS Docker volumes,
and ensure no mount remains under /mnt/cs_storage/vols before purging.
Override only for emergency cleanup with:
  sudo env CSS_STORAGE_PURGE_FORCE=1 apt-get purge -y cs-storage
EOM
    exit 1
  fi
}
case "${1:-}" in
  remove)
    fail_if_css_in_use
    if command -v systemctl >/dev/null 2>&1; then
      systemctl stop cs-storage-auto-upgrade.timer cs-storage-auto-upgrade.service >/dev/null 2>&1 || true
      systemctl disable cs-storage-auto-upgrade.timer >/dev/null 2>&1 || true
      systemctl stop cs-storage-plugin.service cs-storage-daemon.service cs-storage-server.service >/dev/null 2>&1 || true
      systemctl disable cs-storage-plugin.service cs-storage-daemon.service cs-storage-server.service >/dev/null 2>&1 || true
    fi
    ;;
  upgrade|deconfigure)
    ;;
esac
EOF
chmod 0755 "$pkg_root/DEBIAN/prerm"

cat > "$pkg_root/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -eu
if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed cs-storage-plugin.service cs-storage-daemon.service cs-storage-server.service cs-storage-auto-upgrade.service >/dev/null 2>&1 || true
fi
if test "${1:-}" = purge; then
  force=0
  if test "${CSS_STORAGE_PURGE_FORCE:-}" = "1" || test "${CSS_FORCE_PURGE:-}" = "1"; then
    force=1
  fi
  if command -v chattr >/dev/null 2>&1 && test -d /mnt/cs_storage; then
    chattr -R -i /mnt/cs_storage >/dev/null 2>&1 || true
  fi
  if test -d /mnt/cs_storage && command -v find >/dev/null 2>&1; then
    find /mnt/cs_storage -depth -type d -name mount -exec umount -l {} \; >/dev/null 2>&1 || true
  fi
  if command -v findmnt >/dev/null 2>&1 && findmnt -R /mnt/cs_storage/vols >/dev/null 2>&1 && test "$force" != "1"; then
    mounts=$(findmnt -R /mnt/cs_storage/vols -n -o TARGET 2>/dev/null | tr '\n' ' ' || true)
    echo "CSS_PURGE_BLOCKED: active mounts remain under /mnt/cs_storage/vols: $mounts" >&2
    echo "Stop the owning containers/stacks, then rerun purge. Emergency override: sudo env CSS_STORAGE_PURGE_FORCE=1 apt-get purge -y cs-storage" >&2
    exit 1
  fi
  rm -rf /etc/cs-storage /var/lib/cs-storage /var/log/cs-storage /mnt/cs_storage
  rm -f \
    /run/cs-storage.sock \
    /run/docker/plugins/css.sock \
    /run/docker/plugins/cs-storage.sock \
    /etc/docker/plugins/cs-storage.spec \
    /etc/docker/plugins/cs-storage.json \
    /usr/local/bin/cs-storage-server \
    /usr/local/bin/cs-storage-daemon \
    /usr/local/bin/cs-storage-plugin \
    /usr/local/bin/cs-storage-admin \
    /usr/local/bin/cs-storage-router \
    /usr/local/sbin/cs-storage-systemd-node-install \
    /usr/local/sbin/cs-storage-firewall-ensure \
    /usr/local/sbin/css-install-common \
    /usr/local/sbin/css-install-server \
    /usr/local/sbin/css-install-client \
    /usr/local/sbin/css-install-all
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
