#!/bin/sh
set -eu
STACK=${STACK:-cs-storage-cluster-preflight}
IMAGE=${IMAGE:-alpine:3.20}
SMOKE=${SMOKE:-/tmp/cs-cluster-preflight}
STRICT=${STRICT:-0}
NODES_MIN=${NODES_MIN:-}
TOOLS=${TOOLS:-litefs mount.glusterfs gluster sqlite3 rclone gocryptfs kopia fusermount3 fusermount}
MISSING_TSV=${MISSING_TSV:-$SMOKE/missing.tsv}
PLAN_OUT=${PLAN_OUT:-$SMOKE/install-plan.sh}
PACKAGES_TSV=${PACKAGES_TSV:-$SMOKE/packages.tsv}
MANUAL_TSV=${MANUAL_TSV:-$SMOKE/manual.tsv}
VERIFY_OUT=${VERIFY_OUT:-$SMOKE/verify-after-install.sh}
COLLECTED_LOGS=${COLLECTED_LOGS:-$SMOKE/collected-logs.txt}
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
trap cleanup EXIT
state=$(docker info --format '{{.Swarm.LocalNodeState}}')
if test "$state" != "active"; then
  echo "SWARM_NOT_ACTIVE state=$state"
  exit 1
fi
active_nodes=$(docker node ls --format '{{.Status}}' | awk '$1 == "Ready" {n++} END {print n+0}')
if test -z "$NODES_MIN"; then
  NODES_MIN=$active_nodes
fi
if test "$active_nodes" -lt "$NODES_MIN"; then
  echo "CLUSTER_PREFLIGHT_NOT_ENOUGH_NODES ready=$active_nodes min=$NODES_MIN"
  exit 1
fi
cat > "$SMOKE/stack.yml" <<'EOF'
version: "3.8"
services:
  probe:
    image: ${IMAGE}
    command:
      - /bin/sh
      - -c
      - |
        set -eu
        mkdir -p /www
        node=$$(cat /host/etc/hostname 2>/dev/null || hostname)
        {
          echo "NODE $$node"
          for tool in $$TOOLS; do
            found=""
            for dir in /host/bin /host/sbin /host/usr/bin /host/usr/sbin /host/usr/local/bin /host/usr/local/sbin; do
              if test -x "$$dir/$$tool"; then
                found="$${dir#/host}/$$tool"
                break
              fi
            done
            if test -n "$$found"; then
              echo "FOUND $$node $$tool $$found"
            else
              echo "MISSING $$node $$tool"
            fi
          done
        } > /www/result.txt
        cat /www/result.txt
        while true; do { printf "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n"; cat /www/result.txt; } | nc -l -p 8080; done
    environment:
      TOOLS: "${TOOLS}"
    volumes:
      - type: bind
        source: /
        target: /host
        read_only: true
    networks:
      - preflight
    deploy:
      mode: global
      restart_policy:
        condition: none
networks:
  preflight:
    driver: overlay
    attachable: true
EOF
sed -i "s|\${IMAGE}|$IMAGE|g; s|\${TOOLS}|$TOOLS|g" "$SMOKE/stack.yml"
docker stack deploy -c "$SMOKE/stack.yml" "$STACK" >/dev/null
service="${STACK}_probe"
for _ in $(seq 1 120); do
  nodes=$(docker service ps "$service" --filter desired-state=running --format '{{.Node}} {{.CurrentState}}' 2>/dev/null | awk '$2 == "Running" {print $1}' | sort -u | wc -l)
  if test "$nodes" -ge "$NODES_MIN"; then
    break
  fi
  sleep 1
done
nodes=$(docker service ps "$service" --filter desired-state=running --format '{{.Node}} {{.CurrentState}}' 2>/dev/null | awk '$2 == "Running" {print $1}' | sort -u | wc -l)
if test "$nodes" -lt "$NODES_MIN"; then
  docker service ps "$service" --no-trunc || true
  echo "CLUSTER_PREFLIGHT_NOT_RUNNING nodes=$nodes min=$NODES_MIN ready=$active_nodes"
  exit 1
fi
sleep 2
network="${STACK}_preflight"
collect_status=1
if docker run --rm --network "$network" "$IMAGE" /bin/sh -c '
  set -eu
  : > /tmp/ips
  for name in "tasks.'"$service"'" "tasks.probe"; do
    if busybox nslookup "$name" >/tmp/nslookup.out 2>/dev/null; then
      while read -r a b c rest; do
        ip=""
        if test "$a" = "Address:"; then
          ip="$b"
        elif test "$a" = "Address"; then
          ip="$c"
        fi
        ip="${ip%%:*}"
        case "$ip" in
          ""|127.*|*[!0-9.]*) ;;
          *.*.*.*) echo "$ip" >> /tmp/ips ;;
        esac
      done < /tmp/nslookup.out
    fi
  done
  sort -u /tmp/ips > /tmp/ips.sorted
  test -s /tmp/ips.sorted
  for ip in $(cat /tmp/ips.sorted); do
    busybox wget -q -T 5 -O- "http://$ip:8080/result.txt" || true
  done
' > "$COLLECTED_LOGS" 2> "$SMOKE/collect.err"; then
  collect_status=0
fi
if test "$collect_status" = "0"; then
  cp "$COLLECTED_LOGS" "$SMOKE/logs.txt"
else
  : > "$SMOKE/logs.txt"
fi
collected_nodes=$(awk '$1 == "NODE" {print $2}' "$SMOKE/logs.txt" | sort -u | wc -l | tr -d ' ')
if test "$collected_nodes" -lt "$NODES_MIN"; then
  timeout 20s docker service logs --raw "$service" >> "$SMOKE/logs.txt" 2>&1 || true
fi
cat "$SMOKE/logs.txt"
awk '$1 == "MISSING" {print $2 "\t" $3}' "$SMOKE/logs.txt" | sort -u > "$MISSING_TSV"
LOGGED_NODES_TSV=${LOGGED_NODES_TSV:-$SMOKE/logged-nodes.tsv}
awk '$1 == "NODE" {print $2}' "$SMOKE/logs.txt" | sort -u > "$LOGGED_NODES_TSV"
logged_nodes=$(wc -l < "$LOGGED_NODES_TSV" | tr -d ' ')
missing=$(wc -l < "$MISSING_TSV" | tr -d ' ')
generate_plan() {
  if test -s "$MISSING_TSV"; then
    awk '
      function pkg(tool) {
        if (tool == "mount.glusterfs" || tool == "gluster") return "glusterfs-client"
        if (tool == "sqlite3") return "sqlite3"
        if (tool == "rclone") return "rclone"
        if (tool == "gocryptfs") return "gocryptfs"
        if (tool == "fusermount3") return "fuse3"
        if (tool == "fusermount") return "fuse"
        return ""
      }
      {
        package=pkg($2)
        if (package != "") print $1 "\t" package "\t" $2
      }
    ' "$MISSING_TSV" | sort -u > "$PACKAGES_TSV"
    awk '
      function pkg(tool) {
        if (tool == "mount.glusterfs" || tool == "gluster") return "glusterfs-client"
        if (tool == "sqlite3") return "sqlite3"
        if (tool == "rclone") return "rclone"
        if (tool == "gocryptfs") return "gocryptfs"
        if (tool == "fusermount3") return "fuse3"
        if (tool == "fusermount") return "fuse"
        return ""
      }
      {
        if (pkg($2) == "") {
          note="install manually and place in PATH"
          if ($2 == "litefs") note="install Fly.io LiteFS release and place litefs in /usr/local/bin"
          if ($2 == "kopia") note="install Kopia from official package/repository and place kopia in PATH"
          print $1 "\t" $2 "\t" note
        }
      }
    ' "$MISSING_TSV" | sort -u > "$MANUAL_TSV"
  else
    : > "$PACKAGES_TSV"
    : > "$MANUAL_TSV"
  fi
  {
    echo '#!/bin/sh'
    echo 'set -eu'
    echo '# Generated by scripts/hd01-cluster-preflight.sh.'
    echo "# Logged nodes: $logged_nodes of required $NODES_MIN. If partial, do not treat this as a complete install plan."
    echo '# Default mode is review-only. It never installs packages unless APPLY=1 is set.'
    echo 'APPLY=${APPLY:-0}'
    echo
    echo 'cat <<"EOF"'
    echo '# Missing CS-Storage prerequisites by node/tool:'
    if test -s "$MISSING_TSV"; then
      awk '{print "# " $1 " missing " $2}' "$MISSING_TSV"
    else
      echo '# none'
    fi
    echo 'EOF'
    echo
    echo 'if test "$APPLY" != "1"; then'
    echo '  echo "DRY_RUN: review this plan first. Re-run with APPLY=1 only after approving host changes."'
    echo '  echo "Packages table: '"$PACKAGES_TSV"'"'
    echo '  echo "Manual installs table: '"$MANUAL_TSV"'"'
    echo '  echo "Verification command: '"$VERIFY_OUT"'"'
    echo '  exit 0'
    echo 'fi'
    echo
    echo 'cat <<"EOF"'
    echo '# Run the following package commands on the matching nodes, then handle manual installs.'
    if test -s "$PACKAGES_TSV"; then
      awk '
        {
          key=$1 SUBSEP $2
          if (!(key in seen)) {
            seen[key]=1
            pkgs[$1]=pkgs[$1] " " $2
          }
        }
        END {
          for (node in pkgs) {
            printf("# Node: %s\n", node)
            printf("sudo apt-get update && sudo apt-get install -y%s\n", pkgs[node])
          }
        }
      ' "$PACKAGES_TSV"
    else
      echo '# no apt-managed packages missing'
    fi
    if test -s "$MANUAL_TSV"; then
      awk '{print "# Node: " $1 " manual: " $2 " - " substr($0, index($0,$3))}' "$MANUAL_TSV"
    fi
    echo 'EOF'
  } > "$PLAN_OUT"
  chmod 700 "$PLAN_OUT"
  {
    echo '#!/bin/sh'
    echo 'set -eu'
    echo '# Re-run after host dependency installation to prove all prerequisites are present.'
    printf 'SMOKE=%s STRICT=1 TOOLS="%s" %s\n' "$SMOKE/verify" "$TOOLS" './scripts/hd01-cluster-preflight.sh'
  } > "$VERIFY_OUT"
  chmod 700 "$VERIFY_OUT"
}

generate_plan
trap - EXIT
cleanup
if test "$logged_nodes" -lt "$NODES_MIN"; then
  echo "CLUSTER_PREFLIGHT_PARTIAL logged_nodes=$logged_nodes min=$NODES_MIN running_nodes=$nodes ready=$active_nodes image=$IMAGE"
  if test "$STRICT" = "1"; then
    exit 1
  fi
fi
if test "$missing" -gt 0; then
  echo "CLUSTER_PREFLIGHT_PLAN path=$PLAN_OUT missing_tsv=$MISSING_TSV packages_tsv=$PACKAGES_TSV manual_tsv=$MANUAL_TSV logged_nodes_tsv=$LOGGED_NODES_TSV collected_logs=$COLLECTED_LOGS verify=$VERIFY_OUT"
  echo "CLUSTER_PREFLIGHT_MISSING missing=$missing logged_nodes=$logged_nodes nodes=$nodes ready=$active_nodes image=$IMAGE"
  if test "$STRICT" = "1"; then
    exit 1
  fi
else
  echo "CLUSTER_PREFLIGHT_PLAN path=$PLAN_OUT missing_tsv=$MISSING_TSV packages_tsv=$PACKAGES_TSV manual_tsv=$MANUAL_TSV logged_nodes_tsv=$LOGGED_NODES_TSV collected_logs=$COLLECTED_LOGS verify=$VERIFY_OUT"
  echo "CLUSTER_PREFLIGHT_OK logged_nodes=$logged_nodes nodes=$nodes ready=$active_nodes image=$IMAGE"
fi
