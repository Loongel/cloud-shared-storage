#!/bin/sh
set -eu
STACK=${STACK:-cs-storage-plugin-daemon-global-smoke}
IMAGE=${IMAGE:-cs-storage:hd01-smoke}
TESTER_IMAGE=${TESTER_IMAGE:-docker:27-cli}
SMOKE=${SMOKE:-/tmp/cs-storage-plugin-daemon-global-smoke}
NODES_MIN=${NODES_MIN:-}
DRIVER=${DRIVER:-cs-storage-swarm-smoke}
VOLUME=${VOLUME:-cs-swarm-smoke-vol}
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
  echo "PLUGIN_DAEMON_GLOBAL_NOT_ENOUGH_NODES ready=$active_nodes min=$NODES_MIN"
  exit 1
fi
cat > "$SMOKE/stack.yml" <<EOF
version: "3.8"
services:
  daemon:
    image: $IMAGE
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        set -eu
        rm -f /plugins/$DRIVER.daemon
        cleanup() { rm -f /plugins/$DRIVER.daemon; }
        trap cleanup EXIT TERM INT
        CS_DAEMON_SOCKET=/plugins/$DRIVER.daemon \\
        CS_ROOT_DIR=/tmp/cs-storage-plugin-daemon-smoke/vols \\
        CS_STATE_PATH=/tmp/cs-storage-plugin-daemon-smoke/state/volumes.json \\
        CS_AUDIT_LOG=/tmp/cs-storage-plugin-daemon-smoke/state/audit.jsonl \\
        CS_ENABLE_CHATTR=false \\
        CS_RECOVER_MOUNTS=false \\
        /usr/local/bin/cs-storage-daemon &
        pid=\$\$!
        wait \$\$pid
    volumes:
      - type: bind
        source: /run/docker/plugins
        target: /plugins
    deploy:
      mode: global
      restart_policy:
        condition: none
  plugin:
    image: $IMAGE
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        set -eu
        rm -f /plugins/$DRIVER.sock
        cleanup() { rm -f /plugins/$DRIVER.sock; }
        trap cleanup EXIT TERM INT
        CS_PLUGIN_SOCKET=/plugins/$DRIVER.sock \\
        CS_DAEMON_SOCKET=/plugins/$DRIVER.daemon \\
        CS_PLUGIN_TIMEOUT=3s \\
        CS_PLUGIN_SCOPE=local \\
        CS_DOCKER_SOCKET= \\
        /usr/local/bin/cs-storage-plugin &
        pid=\$\$!
        wait \$\$pid
    volumes:
      - type: bind
        source: /run/docker/plugins
        target: /plugins
    deploy:
      mode: global
      restart_policy:
        condition: none
  tester:
    image: $TESTER_IMAGE
    command:
      - sh
      - -c
      - |
        set -eu
        i=0
        while test "\$\$i" -lt 160; do
          if test -S /plugins/$DRIVER.sock && test -S /plugins/$DRIVER.daemon; then
            break
          fi
          i=\$\$((i + 1))
          sleep 0.25
        done
        test -S /plugins/$DRIVER.sock
        test -S /plugins/$DRIVER.daemon
        docker volume rm $VOLUME >/dev/null 2>&1 || true
        docker volume create -d $DRIVER -o cs.crypt=false $VOLUME
        docker volume inspect $VOLUME >/tmp/volume.json
        docker volume rm $VOLUME
        rm -f /plugins/$DRIVER.sock /plugins/$DRIVER.daemon
        echo PLUGIN_DAEMON_GLOBAL_OK driver=$DRIVER volume=$VOLUME
        sleep 20
    volumes:
      - type: bind
        source: /var/run/docker.sock
        target: /var/run/docker.sock
      - type: bind
        source: /run/docker/plugins
        target: /plugins
    deploy:
      mode: global
      restart_policy:
        condition: none
EOF
docker stack deploy -c "$SMOKE/stack.yml" "$STACK" >/dev/null
tester="${STACK}_tester"
for _ in $(seq 1 180); do
  ok=$(docker service logs --raw "$tester" 2>/dev/null | awk '$1 == "PLUGIN_DAEMON_GLOBAL_OK" {n++} END {print n+0}')
  running=$(docker service ps "$tester" --filter desired-state=running --format '{{.Node}} {{.CurrentState}}' 2>/dev/null | awk '$2 == "Running" {print $1}' | sort -u | wc -l)
  failed=$(docker service ps "$tester" --format '{{.CurrentState}}' 2>/dev/null | awk '$1 == "Failed" || $1 == "Rejected" {n++} END {print n+0}')
  if test "$ok" -ge "$NODES_MIN" || { test "$running" -ge "$NODES_MIN" && test "$ok" -gt 0 && test "$failed" -eq 0; }; then
    break
  fi
  sleep 1
done
logs="$SMOKE/logs.txt"
docker service logs --raw "$tester" > "$logs" 2>&1 || true
cat "$logs"
ok=$(awk '$1 == "PLUGIN_DAEMON_GLOBAL_OK" {n++} END {print n+0}' "$logs")
running=$(docker service ps "$tester" --filter desired-state=running --format '{{.Node}} {{.CurrentState}}' 2>/dev/null | awk '$2 == "Running" {print $1}' | sort -u | wc -l)
failed=$(docker service ps "$tester" --format '{{.CurrentState}}' 2>/dev/null | awk '$1 == "Failed" || $1 == "Rejected" {n++} END {print n+0}')
if test "$ok" -lt "$NODES_MIN" && { test "$running" -lt "$NODES_MIN" || test "$failed" -gt 0 || test "$ok" -eq 0; }; then
  docker service ps "${STACK}_daemon" --no-trunc || true
  docker service ps "${STACK}_plugin" --no-trunc || true
  docker service ps "$tester" --no-trunc || true
  echo DAEMON_LOGS
  docker service logs --raw "${STACK}_daemon" --tail 80 2>&1 || true
  echo PLUGIN_LOGS
  docker service logs --raw "${STACK}_plugin" --tail 80 2>&1 || true
  echo "PLUGIN_DAEMON_GLOBAL_SMOKE_NOT_READY ok=$ok running=$running failed=$failed min=$NODES_MIN ready=$active_nodes image=$IMAGE tester=$TESTER_IMAGE"
  exit 1
fi
if test "$ok" -lt "$NODES_MIN"; then
  echo "PLUGIN_DAEMON_GLOBAL_LOGS_PARTIAL ok=$ok running=$running min=$NODES_MIN image=$IMAGE tester=$TESTER_IMAGE"
  ok=$running
fi
trap - EXIT
cleanup
echo "PLUGIN_DAEMON_GLOBAL_SMOKE_OK nodes=$ok ready=$active_nodes image=$IMAGE tester=$TESTER_IMAGE driver=$DRIVER"
