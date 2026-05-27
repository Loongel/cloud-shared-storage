#!/bin/sh
set -eu

if test "${CSS_ALLOW_HISTORICAL_SWARM_HOST_HELPER:-}" != "yes"; then
  cat >&2 <<'EOF'
CSS_HISTORICAL_SWARM_HOST_HELPER_DISABLED

This historical helper uses Swarm to load images on nodes. It is not part of
the deb/systemd production install path and is disabled by default.
EOF
  exit 2
fi

STACK=${STACK:-cs-storage-image-load-smoke}
IMAGE=${IMAGE:-cs-storage:hd01-smoke}
LOADER_IMAGE=${LOADER_IMAGE:-docker:27-cli}
SERVER_IMAGE=${SERVER_IMAGE:-busybox:1.36}
SMOKE=${SMOKE:-/tmp/cs-storage-image-load-smoke}
NODES_MIN=${NODES_MIN:-}
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
  echo "IMAGE_LOAD_NOT_ENOUGH_NODES ready=$active_nodes min=$NODES_MIN"
  exit 1
fi
docker image inspect "$IMAGE" >/dev/null
archive="$SMOKE/image.tar"
docker save -o "$archive" "$IMAGE"
manager_host=$(docker node inspect self --format '{{.Description.Hostname}}')
cat > "$SMOKE/stack.yml" <<EOF
version: "3.8"
services:
  image-server:
    image: $SERVER_IMAGE
    command: ["httpd", "-f", "-p", "8080", "-h", "/data"]
    volumes:
      - type: bind
        source: $SMOKE
        target: /data
        read_only: true
    networks:
      - imagebus
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.hostname == $manager_host
      restart_policy:
        condition: none
  loader:
    image: $LOADER_IMAGE
    command:
      - sh
      - -c
      - |
        set -eu
        for i in \$\$(seq 1 60); do
          if wget -qO /tmp/cs-storage-image.tar http://image-server:8080/image.tar; then
            break
          fi
          if test "\$\$i" -eq 60; then
            echo IMAGE_LOAD_DOWNLOAD_FAILED node=\$\$(hostname) attempts=\$\$i
            exit 1
          fi
          sleep 1
        done
        docker load -i /tmp/cs-storage-image.tar >/tmp/docker-load.out
        docker image inspect $IMAGE >/dev/null
        cat /tmp/docker-load.out
        echo IMAGE_LOADED node=\$\$(hostname) image=$IMAGE
        sleep 20
    volumes:
      - type: bind
        source: /var/run/docker.sock
        target: /var/run/docker.sock
    networks:
      - imagebus
    deploy:
      mode: global
      restart_policy:
        condition: none
networks:
  imagebus:
    driver: overlay
EOF
docker stack deploy -c "$SMOKE/stack.yml" "$STACK" >/dev/null
server="${STACK}_image-server"
loader="${STACK}_loader"
for _ in $(seq 1 120); do
  server_running=$(docker service ps "$server" --filter desired-state=running --format '{{.CurrentState}}' 2>/dev/null | awk '$1 == "Running" {n++} END {print n+0}')
  if test "$server_running" -ge 1; then
    break
  fi
  sleep 1
done
server_running=$(docker service ps "$server" --filter desired-state=running --format '{{.CurrentState}}' 2>/dev/null | awk '$1 == "Running" {n++} END {print n+0}')
if test "$server_running" -lt 1; then
  docker service ps "$server" --no-trunc || true
  echo "IMAGE_LOAD_SERVER_NOT_RUNNING image=$SERVER_IMAGE"
  exit 1
fi
for _ in $(seq 1 240); do
  loaded=$(docker service logs --raw "$loader" 2>/dev/null | awk '$1 == "IMAGE_LOADED" {n++} END {print n+0}')
  completed=$(docker service ps "$loader" --format '{{.CurrentState}}' 2>/dev/null | awk '$1 == "Complete" {n++} END {print n+0}')
  failed=$(docker service ps "$loader" --format '{{.CurrentState}}' 2>/dev/null | awk '$1 == "Failed" || $1 == "Rejected" {n++} END {print n+0}')
  if test "$loaded" -ge "$NODES_MIN" || { test "$completed" -ge "$NODES_MIN" && test "$failed" -eq 0; }; then
    break
  fi
  sleep 1
done
logs="$SMOKE/logs.txt"
docker service logs --raw "$loader" > "$logs" 2>&1 || true
cat "$logs"
loaded=$(awk '$1 == "IMAGE_LOADED" {n++} END {print n+0}' "$logs")
completed=$(docker service ps "$loader" --format '{{.CurrentState}}' 2>/dev/null | awk '$1 == "Complete" {n++} END {print n+0}')
failed=$(docker service ps "$loader" --format '{{.CurrentState}}' 2>/dev/null | awk '$1 == "Failed" || $1 == "Rejected" {n++} END {print n+0}')
if test "$loaded" -lt "$NODES_MIN" && { test "$completed" -lt "$NODES_MIN" || test "$failed" -gt 0; }; then
  docker service ps "$loader" --no-trunc || true
  echo "IMAGE_LOAD_SMOKE_NOT_ENOUGH_NODES loaded=$loaded completed=$completed failed=$failed min=$NODES_MIN ready=$active_nodes image=$IMAGE"
  exit 1
fi
if test "$loaded" -lt "$NODES_MIN"; then
  echo "IMAGE_LOAD_LOGS_PARTIAL loaded=$loaded completed=$completed min=$NODES_MIN image=$IMAGE"
  loaded=$completed
fi
trap - EXIT
cleanup
echo "IMAGE_LOAD_SMOKE_OK nodes=$loaded ready=$active_nodes image=$IMAGE loader=$LOADER_IMAGE server=$SERVER_IMAGE"
