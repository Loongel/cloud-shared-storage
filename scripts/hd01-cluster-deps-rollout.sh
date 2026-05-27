#!/bin/sh
set -eu

cat >&2 <<'EOF'
CSS_CLUSTER_DEPS_ROLLOUT_REMOVED

This historical helper is intentionally disabled.

Do not use Docker Swarm services or helper containers to install host
dependencies or mutate host files across nodes. CSS production dependencies and
runtime tools are owned by the cs-storage deb package on each node, upgraded
locally by apt/systemd through cs-storage-auto-upgrade.timer.

Use one of the role installers locally on each node, or let the deb-managed
auto-upgrade service pull the GitHub Release package:

  sudo systemctl enable --now cs-storage-auto-upgrade.timer
  sudo systemctl start cs-storage-auto-upgrade.service

Swarm/Stack is reserved for post-install workload validation only.
EOF
exit 2

STACK=${STACK:-cs-storage-cluster-deps-rollout}
IMAGE=${IMAGE:-cs-storage:hd01-smoke}
SMOKE=${SMOKE:-/tmp/cs-cluster-deps-rollout}
PREFLIGHT_SMOKE=${PREFLIGHT_SMOKE:-/tmp/cs-cluster-preflight-collector}
APPLY=${APPLY:-0}
ACK_INSTALL_HOST_DEPS=${ACK_INSTALL_HOST_DEPS:-}
NODES_MIN=${NODES_MIN:-}
APT_PACKAGES=${APT_PACKAGES:-glusterfs-client glusterfs-server sqlite3 rclone gocryptfs fuse3}
COPY_BINS=${COPY_BINS:-litefs kopia}
VERIFY_TOOLS=${VERIFY_TOOLS:-litefs mount.glusterfs gluster sqlite3 rclone gocryptfs kopia fusermount3}

rm -rf "$SMOKE"
mkdir -p "$SMOKE"

cleanup() {
  docker stack rm "$STACK" >/dev/null 2>&1 || true
  for _ in $(seq 1 60); do
    if ! docker stack ps "$STACK" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
}

state=$(docker info --format '{{.Swarm.LocalNodeState}}')
if test "$state" != "active"; then
  echo "CLUSTER_DEPS_SWARM_NOT_ACTIVE state=$state"
  exit 1
fi
active_nodes=$(docker node ls --format '{{.Status}}' | awk '$1 == "Ready" {n++} END {print n+0}')
if test -z "$NODES_MIN"; then
  NODES_MIN=$active_nodes
fi
if test "$active_nodes" -lt "$NODES_MIN"; then
  echo "CLUSTER_DEPS_NOT_ENOUGH_NODES ready=$active_nodes min=$NODES_MIN"
  exit 1
fi

docker image inspect "$IMAGE" >/dev/null

if test "$APPLY" != "1"; then
  echo "CLUSTER_DEPS_ROLLOUT_DRY_RUN image=$IMAGE ready=$active_nodes min=$NODES_MIN"
  echo "Would install apt packages on each Ready node: $APT_PACKAGES"
  echo "Would copy runtime binaries from image to /usr/local/bin on each Ready node: $COPY_BINS"
  echo "Would verify tools after install: $VERIFY_TOOLS"
  if test -s "$PREFLIGHT_SMOKE/missing.tsv"; then
    echo "Current missing node/tool entries from $PREFLIGHT_SMOKE/missing.tsv:"
    sed -n '1,120p' "$PREFLIGHT_SMOKE/missing.tsv"
  fi
  echo "To apply host changes, rerun with APPLY=1 ACK_INSTALL_HOST_DEPS=yes. Review package/network impact first."
  exit 0
fi

if test "$ACK_INSTALL_HOST_DEPS" != "yes"; then
  echo "CLUSTER_DEPS_REFUSE_APPLY missing_ack=ACK_INSTALL_HOST_DEPS=yes"
  exit 1
fi

trap cleanup EXIT
cat > "$SMOKE/stack.yml" <<EOF
version: "3.8"
services:
  rollout:
    image: $IMAGE
    entrypoint:
      - /bin/sh
      - -c
    command:
      - |
        set -eu
        node=\$\$(cat /host/etc/hostname 2>/dev/null || hostname)
        log=/host/var/log/cs-storage/deps-rollout.log
        mkdir -p /host/var/log/cs-storage /host/usr/local/bin
        set +e
        {
          echo "CLUSTER_DEPS_NODE_BEGIN node=\$\$node"
          if ! test -x /host/usr/bin/apt-get; then
            echo "CLUSTER_DEPS_NODE_ERROR node=\$\$node reason=apt-get-missing"
            exit 1
          fi
          if test -x /host/usr/bin/dpkg; then
            chroot /host /usr/bin/env DEBIAN_FRONTEND=noninteractive dpkg --configure -a
          fi
          chroot /host /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get update
          chroot /host /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $APT_PACKAGES
          for bin in $COPY_BINS; do
            if ! test -x /usr/local/bin/\$\$bin; then
              echo "CLUSTER_DEPS_NODE_ERROR node=\$\$node reason=missing-image-bin bin=\$\$bin"
              exit 1
            fi
            cp /usr/local/bin/\$\$bin /host/usr/local/bin/\$\$bin
            chmod 0755 /host/usr/local/bin/\$\$bin
          done
          missing=""
          for tool in $VERIFY_TOOLS; do
            if ! chroot /host /bin/sh -c "command -v \$\$tool >/dev/null 2>&1"; then
              missing="\$\$missing \$\$tool"
            fi
          done
          if test -n "\$\$missing"; then
            echo "CLUSTER_DEPS_NODE_ERROR node=\$\$node missing=\$\$missing"
            exit 1
          fi
          echo "CLUSTER_DEPS_NODE_OK node=\$\$node packages=\"$APT_PACKAGES\" bins=\"$COPY_BINS\""
        } > "\$\$log.tmp" 2>&1
        rc=\$\$?
        set -e
        cat "\$\$log.tmp" | tee -a "\$\$log"
        rm -f "\$\$log.tmp"
        exit "\$\$rc"
    volumes:
      - type: bind
        source: /
        target: /host
    deploy:
      mode: global
      restart_policy:
        condition: none
EOF

docker stack deploy -c "$SMOKE/stack.yml" "$STACK" >/dev/null
service="${STACK}_rollout"
for _ in $(seq 1 900); do
  timeout 20s docker service logs --raw "$service" > "$SMOKE/live-logs.txt" 2>/dev/null || true
  docker service ps "$service" --no-trunc --format '{{.Node}}|{{.CurrentState}}|{{.Error}}' > "$SMOKE/service-ps.txt" 2>/dev/null || true
  ok=$(awk '$1 == "CLUSTER_DEPS_NODE_OK" {n++} END {print n+0}' "$SMOKE/live-logs.txt")
  completed=$(awk -F'|' '$2 ~ /^Complete/ {print $1}' "$SMOKE/service-ps.txt" | sort -u | wc -l | tr -d ' ')
  err=$(awk '$1 == "CLUSTER_DEPS_NODE_ERROR" {n++} END {print n+0}' "$SMOKE/live-logs.txt")
  failed=$(awk -F'|' '$2 ~ /^Failed|^Rejected/ || $3 != "" {n++} END {print n+0}' "$SMOKE/service-ps.txt")
  if test "$err" -gt 0; then
    break
  fi
  if test "$failed" -gt 0; then
    break
  fi
  if test "$ok" -ge "$NODES_MIN" || test "$completed" -ge "$NODES_MIN"; then
    break
  fi
  sleep 2
done

timeout 30s docker service logs --raw "$service" > "$SMOKE/logs.txt" 2>&1 || true
docker service ps "$service" --no-trunc --format '{{.Node}}|{{.CurrentState}}|{{.Error}}' > "$SMOKE/service-ps.txt" 2>/dev/null || true
cat "$SMOKE/logs.txt"
ok=$(awk '$1 == "CLUSTER_DEPS_NODE_OK" {n++} END {print n+0}' "$SMOKE/logs.txt")
completed=$(awk -F'|' '$2 ~ /^Complete/ {print $1}' "$SMOKE/service-ps.txt" | sort -u | wc -l | tr -d ' ')
err=$(awk '$1 == "CLUSTER_DEPS_NODE_ERROR" {n++} END {print n+0}' "$SMOKE/logs.txt")
failed=$(awk -F'|' '$2 ~ /^Failed|^Rejected/ || $3 != "" {n++} END {print n+0}' "$SMOKE/service-ps.txt")
if test "$err" -gt 0 || test "$failed" -gt 0 || { test "$ok" -lt "$NODES_MIN" && test "$completed" -lt "$NODES_MIN"; }; then
  docker service ps "$service" --no-trunc || true
  echo "CLUSTER_DEPS_ROLLOUT_FAILED ok=$ok completed=$completed errors=$err failed=$failed min=$NODES_MIN ready=$active_nodes image=$IMAGE logs=$SMOKE/logs.txt"
  exit 1
fi

trap - EXIT
cleanup

if test "$ok" -lt "$NODES_MIN"; then
  echo "CLUSTER_DEPS_ROLLOUT_LOGS_PARTIAL ok_logs=$ok completed=$completed min=$NODES_MIN"
  ok=$completed
fi
echo "CLUSTER_DEPS_ROLLOUT_OK nodes=$ok ready=$active_nodes image=$IMAGE packages=\"$APT_PACKAGES\" bins=\"$COPY_BINS\""
