#!/bin/sh
set -eu

STACK=${STACK:-cs-storage-production-path-preflight}
IMAGE=${IMAGE:-alpine:3.20}
SMOKE=${SMOKE:-/tmp/cs-storage-production-path-preflight}
STRICT=${STRICT:-0}
NODES_MIN=${NODES_MIN:-}
ISSUES_TSV=${ISSUES_TSV:-$SMOKE/issues.tsv}

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
  echo "PRODUCTION_PATH_PREFLIGHT_NOT_ENOUGH_NODES ready=$active_nodes min=$NODES_MIN"
  exit 1
fi

cat > "$SMOKE/stack.yml" <<'STACK_EOF'
version: "3.8"
services:
  probe:
    image: ${IMAGE}
    command:
      - /bin/sh
      - -c
      - |
        set -eu
        host=/host
        hostproc=/hostproc
        node=$$(cat "$$host/etc/hostname" 2>/dev/null || hostname)
        issue=0

        pass() {
          echo "PASS $$node $$1 $$2"
        }

        warn() {
          issue=$$((issue + 1))
          echo "ISSUE $$node $$1 $$2"
        }

        skip() {
          echo "SKIP $$node $$1 $$2"
        }

        require_dir() {
          if test -d "$$host$$2"; then
            pass "$$1" "path=$$2"
          else
            warn "$$1" "missing_dir=$$2"
          fi
        }

        require_socket() {
          if test -S "$$host$$2"; then
            pass "$$1" "socket=$$2"
          elif test "$$2" = "/var/run/docker.sock" && test -S "$$host/run/docker.sock"; then
            pass "$$1" "socket=/var/run/docker.sock actual=/run/docker.sock"
          else
            warn "$$1" "missing_socket=$$2"
          fi
        }

        require_char() {
          if test -c "$$host$$2"; then
            pass "$$1" "char_device=$$2"
          else
            warn "$$1" "missing_char_device=$$2"
          fi
        }

        mount_state() {
          target=$$1
          awk -v target="$$target" '
            function unesc(s) {
              gsub(/\\040/, " ", s)
              gsub(/\\011/, "\t", s)
              gsub(/\\012/, "\n", s)
              gsub(/\\134/, "\\", s)
              return s
            }
            {
              mp = unesc($$5)
              if (target == mp || mp == "/" || index(target, mp "/") == 1) {
                if (length(mp) > best) {
                  best = length(mp)
                  line = $$0
                  mountpoint = mp
                }
              }
            }
            END {
              if (line == "") exit 2
              if (line ~ / shared:[0-9]+/) print "shared " mountpoint
              else print "not_shared " mountpoint
            }
          ' "$$hostproc/1/mountinfo" 2>/dev/null || true
        }

        require_dir docker_plugins /run/docker/plugins
        require_socket docker_socket /var/run/docker.sock
        require_char fuse_device /dev/fuse
        require_dir volume_root /mnt/cs_storage/vols
        require_dir log_root /var/log/cs-storage

        if test -d "$$host/mnt/cs_storage/vols"; then
          state=$$(mount_state /mnt/cs_storage/vols)
          if test -z "$$state"; then
            warn volume_root_propagation "mountinfo_unavailable target=/mnt/cs_storage/vols"
          else
            kind=$$(printf '%s\n' "$$state" | awk '{print $$1}')
            mountpoint=$$(printf '%s\n' "$$state" | awk '{print $$2}')
            if test "$$kind" = "shared"; then
              pass volume_root_propagation "mountpoint=$$mountpoint state=shared"
            else
              warn volume_root_propagation "mountpoint=$$mountpoint state=not_shared"
            fi
          fi
        else
          skip volume_root_propagation "prerequisite_missing path=/mnt/cs_storage/vols"
        fi

        if test "$$issue" -eq 0; then
          echo "NODE_PRODUCTION_PATH_PREFLIGHT_OK $$node"
        else
          echo "NODE_PRODUCTION_PATH_PREFLIGHT_ISSUES $$node issues=$$issue"
        fi
        sleep 300
    volumes:
      - type: bind
        source: /
        target: /host
        read_only: true
      - type: bind
        source: /proc
        target: /hostproc
        read_only: true
    deploy:
      mode: global
      restart_policy:
        condition: none
STACK_EOF

sed -i "s|\${IMAGE}|$IMAGE|g" "$SMOKE/stack.yml"
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
  echo "PRODUCTION_PATH_PREFLIGHT_NOT_RUNNING nodes=$nodes min=$NODES_MIN ready=$active_nodes"
  exit 1
fi

sleep 2
docker service logs --raw "$service" > "$SMOKE/logs.txt" 2>&1 || true
cat "$SMOKE/logs.txt"
awk '$1 == "ISSUE" {print $2 "\t" $3 "\t" $4}' "$SMOKE/logs.txt" | sort -u > "$ISSUES_TSV"
issues=$(wc -l < "$ISSUES_TSV" | tr -d ' ')

trap - EXIT
cleanup

if test "$issues" -gt 0; then
  echo "PRODUCTION_PATH_PREFLIGHT_ISSUES issues=$issues nodes=$nodes ready=$active_nodes image=$IMAGE issues_tsv=$ISSUES_TSV"
  if test "$STRICT" = "1"; then
    exit 1
  fi
else
  echo "PRODUCTION_PATH_PREFLIGHT_OK nodes=$nodes ready=$active_nodes image=$IMAGE issues_tsv=$ISSUES_TSV"
fi
