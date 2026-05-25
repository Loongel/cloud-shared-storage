#!/bin/sh
set -eu
GO_BIN=${GO_BIN:-/tmp/cs-storage-go/go/bin/go}
WORKDIR=${WORKDIR:-/tmp/cs-storage-work-current}
SMOKE=${SMOKE:-/tmp/cs-storage-restore-admin-smoke}
cd "$WORKDIR"
"$GO_BIN" build -buildvcs=false -o /tmp/cs-storage-admin ./cmd/cs-storage-admin
rm -rf "$SMOKE"
mkdir -p "$SMOKE/bin" "$SMOKE/root/vol1/mount" "$SMOKE/remote/backups/vol1/20260521-010000" "$SMOKE/remote/backups/vol1/20260522-010000"
printf old > "$SMOKE/root/vol1/mount/old.txt"
printf restored > "$SMOKE/remote/backups/vol1/20260522-010000/new.txt"
cat > "$SMOKE/bin/rclone" <<'EOF'
#!/bin/sh
set -eu
if test "$1" = "lsf"; then
  case "$2" in
    remote:backups/vol1)
      printf '20260521-010000/
20260522-010000/
'
      exit 0
      ;;
  esac
fi
if test "$1" = "copy"; then
  src=$2
  dst=$3
  case "$src" in
    remote:backups/vol1/20260522-010000)
      mkdir -p "$dst"
      cp /tmp/cs-storage-restore-admin-smoke/remote/backups/vol1/20260522-010000/new.txt "$dst/new.txt"
      exit 0
      ;;
  esac
fi
echo "unexpected rclone args: $*" >&2
exit 2
EOF
chmod +x "$SMOKE/bin/rclone"
out=$(/tmp/cs-storage-admin restore -source-root remote:backups -latest -volume vol1 -root "$SMOKE/root" -rclone "$SMOKE/bin/rclone" -timeout 30s)
printf '%s
' "$out" > "$SMOKE/restore.out"
grep -q 'selected latest backup: remote:backups/vol1/20260522-010000' "$SMOKE/restore.out"
grep -q 'existing target moved to:' "$SMOKE/restore.out"
test -f "$SMOKE/root/vol1/mount/new.txt"
test ! -f "$SMOKE/root/vol1/mount/old.txt"
ls -d "$SMOKE/root/vol1/mount.BAK."* >/dev/null
grep -q old "$SMOKE/root/vol1/mount.BAK."*/old.txt
echo "RESTORE_ADMIN_SMOKE_OK"
