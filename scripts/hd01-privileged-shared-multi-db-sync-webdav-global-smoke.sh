#!/bin/sh
set -eu

WORKDIR=${WORKDIR:-/tmp/cs-storage-work-current}
RUN_ID=${RUN_ID:-$(date +%s)-$$}
STACK=${STACK:-cs-storage-priv-shared-db-sync-webdav-global-smoke}
IMAGE=${IMAGE:-cs-storage:hd01-smoke}
LAUNCHER_IMAGE=${LAUNCHER_IMAGE:-docker:27-cli}
SMOKE=${SMOKE:-/tmp/cs-storage-priv-shared-db-sync-webdav-global-smoke}
NODES_MIN=${NODES_MIN:-}
DRIVER=${DRIVER:-cs-storage-priv-shared-db-sync-webdav-smoke}
VOLUME=${VOLUME:-cs-priv-shared-db-sync-webdav-smoke-vol-$RUN_ID}
DAEMON_CONTAINER=${DAEMON_CONTAINER:-cs-storage-priv-shared-db-sync-webdav-smoke-daemon}
PLUGIN_CONTAINER=${PLUGIN_CONTAINER:-cs-storage-priv-shared-db-sync-webdav-smoke-plugin}
DAEMON_SOCKET=${DAEMON_SOCKET:-/run/cs-storage-priv-shared-db-sync-webdav-smoke.sock}
PLUGIN_SOCKET=${PLUGIN_SOCKET:-/run/docker/plugins/cs-storage-priv-shared-db-sync-webdav-smoke.sock}
ROOT_DIR=${ROOT_DIR:-/mnt/cs_storage/vols/.cs-priv-shared-db-sync-webdav-smoke}
AUDIT_LOG=${AUDIT_LOG:-/var/log/cs-storage/priv-shared-db-sync-webdav-smoke-audit.jsonl}
SERVER_PORT=${SERVER_PORT:-18152}
SERVER_CONTAINER=${SERVER_CONTAINER:-cs-storage-priv-shared-db-sync-webdav-smoke-server}
LITEFS_PORT=${LITEFS_PORT:-20352}
SECRET=${SECRET:-cs-priv-shared-db-sync-webdav-smoke-secret}
COORDINATOR_TOKEN=${COORDINATOR_TOKEN:-cs-priv-shared-db-sync-webdav-smoke-token}
LITEFS_KEY=${LITEFS_KEY:-cs-storage/priv-shared-db-sync-webdav-smoke}
REMOTE_ROOT=${REMOTE_ROOT:-cs-storage-priv-shared-db-sync-webdav-smoke-$(date +%s)-$$}
DB_NAME=${DB_NAME:-main.db}
ROWS=${ROWS:-64}
VERIFY_TIMEOUT=${VERIFY_TIMEOUT:-240}
LOG_FETCH_TIMEOUT=${LOG_FETCH_TIMEOUT:-20}
CS_WEBDAV_ENV_FILE=${CS_WEBDAV_ENV_FILE:-}

if test -n "$CS_WEBDAV_ENV_FILE"; then
  case "$CS_WEBDAV_ENV_FILE" in
    /tmp/*|/run/secrets/*|/etc/cs-storage/*) ;;
    *) echo "REFUSE_WEBDAV_ENV_FILE path=$CS_WEBDAV_ENV_FILE"; exit 1 ;;
  esac
  if test ! -r "$CS_WEBDAV_ENV_FILE"; then
    echo "WEBDAV_ENV_FILE_NOT_READABLE path=$CS_WEBDAV_ENV_FILE"
    exit 1
  fi
  set -a
  . "$CS_WEBDAV_ENV_FILE"
  set +a
fi

: "${CS_WEBDAV_URL:?CS_WEBDAV_URL is required}"
: "${CS_WEBDAV_USER:?CS_WEBDAV_USER is required}"
: "${CS_WEBDAV_PASSWORD:?CS_WEBDAV_PASSWORD is required}"

case "$DRIVER" in
  cs-storage-priv-shared-db-sync-webdav-smoke*) ;;
  *) echo "REFUSE_DRIVER name=$DRIVER"; exit 1 ;;
esac
case "$DAEMON_SOCKET" in
  /run/cs-storage-priv-shared-db-sync-webdav-smoke*.sock) ;;
  *) echo "REFUSE_DAEMON_SOCKET path=$DAEMON_SOCKET"; exit 1 ;;
esac
case "$PLUGIN_SOCKET" in
  /run/docker/plugins/cs-storage-priv-shared-db-sync-webdav-smoke*.sock) ;;
  *) echo "REFUSE_PLUGIN_SOCKET path=$PLUGIN_SOCKET"; exit 1 ;;
esac
case "$ROOT_DIR" in
  /mnt/cs_storage/vols/.cs-priv-shared-db-sync-webdav-smoke|/mnt/cs_storage/vols/.cs-priv-shared-db-sync-webdav-smoke/*) ;;
  *) echo "REFUSE_ROOT_DIR path=$ROOT_DIR"; exit 1 ;;
esac
case "$AUDIT_LOG" in
  /var/log/cs-storage/priv-shared-db-sync-webdav-smoke*) ;;
  *) echo "REFUSE_AUDIT_LOG path=$AUDIT_LOG"; exit 1 ;;
esac

rm -rf "$SMOKE"
mkdir -p "$SMOKE/server-secrets"
chmod 700 "$SMOKE" "$SMOKE/server-secrets"

cleanup_stack() {
  docker stack rm "$STACK" >/dev/null 2>&1 || true
  for _ in $(seq 1 90); do
    if ! docker stack ps "$STACK" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
}

BASE_URL=${CS_WEBDAV_URL%/}
BASE_HOST=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.urlparse(sys.argv[1]).hostname or "")' "$BASE_URL")
if test -z "$BASE_HOST"; then
  echo INVALID_WEBDAV_URL
  exit 1
fi
NETRC="$SMOKE/curl.netrc"
SERVER_SECRETS="$SMOKE/server-secrets"
cleanup_remote() {
  curl -sS -o /dev/null --netrc-file "$NETRC" -X DELETE "$BASE_URL/$REMOTE_ROOT" >/dev/null 2>&1 || true
}
cleanup() {
  cleanup_stack
  docker rm -f "$SERVER_CONTAINER" >/dev/null 2>&1 || true
  cleanup_remote
  rm -f "$NETRC"
  rm -rf "$SERVER_SECRETS"
}
trap cleanup EXIT
umask 077
cat > "$NETRC" <<NETRC_EOF
machine $BASE_HOST
login $CS_WEBDAV_USER
password $CS_WEBDAV_PASSWORD
NETRC_EOF
printf '%s' "$SECRET" > "$SERVER_SECRETS/node-secret"
printf '%s' "$CS_WEBDAV_USER" > "$SERVER_SECRETS/backend-user"
printf '%s' "$CS_WEBDAV_PASSWORD" > "$SERVER_SECRETS/backend-password"
printf '%s' "$COORDINATOR_TOKEN" > "$SERVER_SECRETS/coordinator-token"
umask 022

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
  echo "PRIV_SHARED_DB_SYNC_NOT_ENOUGH_NODES ready=$active_nodes min=$NODES_MIN"
  exit 1
fi

mkcol() {
  rel=$1
  code=$(curl -sS -o /dev/null -w '%{http_code}' --netrc-file "$NETRC" -X MKCOL "$BASE_URL/$rel" || true)
  case "$code" in
    200|201|204|405) return 0 ;;
    *) echo "WEBDAV_MKCOL_FAILED rel=$rel http=$code"; return 1 ;;
  esac
}

cleanup_remote
mkcol "$REMOTE_ROOT"
mkcol "$REMOTE_ROOT/nodes"
for node in $(docker node ls --format '{{.Hostname}} {{.Status}}' | awk '$2 == "Ready" {print $1}' | sort -u); do
  mkcol "$REMOTE_ROOT/nodes/$node"
done

cd "$WORKDIR"
docker rm -f "$SERVER_CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$SERVER_CONTAINER" \
  --network host \
  -e CS_SERVER_ADDR=":$SERVER_PORT" \
  -e CS_NODE_SECRET_KEY_FILE=/run/cs-storage-smoke-secrets/node-secret \
  -e CS_BACKEND_URL="$BASE_URL" \
  -e CS_BACKEND_USER_FILE=/run/cs-storage-smoke-secrets/backend-user \
  -e CS_BACKEND_PASSWORD_FILE=/run/cs-storage-smoke-secrets/backend-password \
  -e CS_SANDBOX_PREFIX="/$REMOTE_ROOT/nodes" \
  -e CS_COORDINATOR_TOKEN_FILE=/run/cs-storage-smoke-secrets/coordinator-token \
  -v "$SERVER_SECRETS:/run/cs-storage-smoke-secrets:ro" \
  --entrypoint /usr/bin/cs-storage-server \
  "$IMAGE" >/tmp/cs-storage-priv-shared-db-sync-server.cid
for _ in $(seq 1 100); do
  if curl -fsS "http://127.0.0.1:$SERVER_PORT/healthz" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
curl -fsS "http://127.0.0.1:$SERVER_PORT/healthz" >/dev/null
server_host=${SERVER_HOST:-$(docker node inspect self --format '{{.Status.Addr}}' 2>/dev/null || hostname -I | awk '{print $1}')}
SERVER_URL="http://$server_host:$SERVER_PORT"
manager_node=$(docker info --format '{{.Name}}')
node_cases=$(docker node ls --format '{{.Hostname}} {{.Status}}' | awk '$2 == "Ready" {print $1}' | sort | while read -r node; do ip=$(docker node inspect "$node" --format '{{.Status.Addr}}'); printf "  %s) node_ip=%s ;;
" "$node" "$ip"; done)

cat > "$SMOKE/runner.sh" <<RUNNER_EOF
#!/bin/sh
set -eu
node_id=\$(docker info --format '{{.Name}}')
case "\$node_id" in
$node_cases
  *) echo PRIV_SHARED_DB_SYNC_UNKNOWN_NODE node=\$node_id; exit 1 ;;
esac
promote=false
if test "\$node_id" = "$manager_node"; then
  promote=true
fi
cleanup() {
  docker ps -aq --filter volume=$VOLUME | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker volume rm $VOLUME >/dev/null 2>&1 || true
  docker rm -f $PLUGIN_CONTAINER $DAEMON_CONTAINER >/dev/null 2>&1 || true
  rm -f /hostrun/${DAEMON_SOCKET#/run/} /hostrun/docker/plugins/${PLUGIN_SOCKET#/run/docker/plugins/}
}
trap cleanup EXIT TERM INT
cleanup
mkdir -p /hostrun/docker/plugins /hostmnt/.cs-priv-shared-db-sync-webdav-smoke /hostlog

docker run -d --name $DAEMON_CONTAINER \
  --network host \
  --privileged --cap-add SYS_ADMIN --device /dev/fuse \
  -e CS_DAEMON_SOCKET=$DAEMON_SOCKET \
  -e CS_ROOT_DIR=$ROOT_DIR \
  -e CS_STATE_PATH=$ROOT_DIR/.state/volumes.json \
  -e CS_AUDIT_LOG=$AUDIT_LOG \
  -e CS_ENABLE_CHATTR=false \
  -e CS_RECOVER_MOUNTS=false \
  -e CS_SERVER_URL=$SERVER_URL \
  -e CS_RCLONE_ENDPOINT=$SERVER_URL \
  -e CS_NODE_ID=\$node_id \
  -e CS_NODE_SECRET_KEY=$SECRET \
  -e CS_RCLONE_SYNC_INTERVAL=2s \
  -e CS_RCLONE_EXTRA_ARGS=--checksum \
  -e CS_LITEFS_LEASE_TYPE=consul \
  -e CS_LITEFS_CONSUL_URL=$SERVER_URL \
  -e CS_LITEFS_CONSUL_KEY=$LITEFS_KEY \
  -e CS_LITEFS_CONSUL_TOKEN=$COORDINATOR_TOKEN \
  -e CS_LITEFS_HTTP_ADDR=:$LITEFS_PORT \
  -e CS_LITEFS_ADVERTISE_URL=http://\$node_ip:$LITEFS_PORT \
  -e CS_LITEFS_HOSTNAME=\$node_id \
  -e CS_LITEFS_CANDIDATE=true \
  -e CS_LITEFS_PROMOTE=\$promote \
  -v /run:/run \
  -v /mnt/cs_storage/vols:/mnt/cs_storage/vols:rshared \
  -v /var/log/cs-storage:/var/log/cs-storage \
  --entrypoint /usr/bin/cs-storage-daemon \
  $IMAGE >/tmp/daemon.cid

docker run -d --name $PLUGIN_CONTAINER \
  -e CS_PLUGIN_SOCKET=$PLUGIN_SOCKET \
  -e CS_DAEMON_SOCKET=$DAEMON_SOCKET \
  -e CS_PLUGIN_TIMEOUT=180s \
  -e CS_PLUGIN_SCOPE=local \
  -v /run/docker/plugins:/run/docker/plugins \
  -v /run:/run \
  --entrypoint /usr/bin/cs-storage-plugin \
  $IMAGE >/tmp/plugin.cid

i=0
while test "\$i" -lt 240; do
  if test -S /hostrun/${DAEMON_SOCKET#/run/} && test -S /hostrun/docker/plugins/${PLUGIN_SOCKET#/run/docker/plugins/}; then
    break
  fi
  i=\$((i + 1))
  sleep 0.25
done
if ! test -S /hostrun/${DAEMON_SOCKET#/run/} || ! test -S /hostrun/docker/plugins/${PLUGIN_SOCKET#/run/docker/plugins/}; then
  echo PRIV_SHARED_DB_SYNC_SOCKET_WAIT_FAILED node=\$node_id
  docker logs $DAEMON_CONTAINER 2>&1 || true
  docker logs $PLUGIN_CONTAINER 2>&1 || true
  exit 1
fi

docker volume create -d $DRIVER -o flush=true -o cs.crypt=false -o cs.mode=shared -o cs.write=multi -o cs.engine=sqlite $VOLUME >/dev/null
if test "\$node_id" = "$manager_node"; then
  wrote=false
  for _ in \$(seq 1 120); do
    if timeout 30s docker run --rm --entrypoint sqlite3 -v $VOLUME:/data $IMAGE /data/$DB_NAME "PRAGMA journal_mode=WAL; PRAGMA busy_timeout=10000; CREATE TABLE IF NOT EXISTS events(node TEXT, n INTEGER, value TEXT, PRIMARY KEY(node,n)); WITH RECURSIVE cnt(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM cnt WHERE x<$ROWS) INSERT OR IGNORE INTO events(node,n,value) SELECT '\$node_id', x, 'priv-shared-sync-'||x FROM cnt;" >/tmp/priv-shared-db-sync-write.out 2>/tmp/priv-shared-db-sync-write.err; then
      wrote=true
      break
    fi
    sleep 0.5
  done
  if test "\$wrote" != true; then
    echo PRIV_SHARED_DB_SYNC_WRITE_FAILED node=\$node_id
    sed -n '1,120p' /tmp/priv-shared-db-sync-write.out 2>/dev/null || true
    sed -n '1,120p' /tmp/priv-shared-db-sync-write.err 2>/dev/null || true
    docker logs $DAEMON_CONTAINER 2>&1 || true
    exit 1
  fi
fi
for _ in \$(seq 1 240); do
  out=\$(timeout 20s docker run --rm --entrypoint sqlite3 -v $VOLUME:/data $IMAGE /data/$DB_NAME "PRAGMA integrity_check; SELECT COUNT(*) FROM events;" 2>/dev/null || true)
  integrity=\$(printf '%s\n' "\$out" | sed -n '1p')
  rows=\$(printf '%s\n' "\$out" | sed -n '2p')
  if test "\$integrity" = ok && test "\$rows" = "$ROWS"; then
    break
  fi
  sleep 0.5
done
out=\$(timeout 20s docker run --rm --entrypoint sqlite3 -v $VOLUME:/data $IMAGE /data/$DB_NAME "PRAGMA integrity_check; SELECT COUNT(*) FROM events;" 2>/dev/null || true)
integrity=\$(printf '%s\n' "\$out" | sed -n '1p')
rows=\$(printf '%s\n' "\$out" | sed -n '2p')
if test "\$integrity" != ok || test "\$rows" != "$ROWS"; then
  echo PRIV_SHARED_DB_SYNC_LOCAL_VERIFY_FAILED node=\$node_id rows=\$rows expected=$ROWS integrity=\$integrity
  docker logs $DAEMON_CONTAINER 2>&1 || true
  find $ROOT_DIR/$VOLUME/logs -maxdepth 1 -type f -print -exec sed -n '1,120p' {} \; 2>/dev/null || true
  exit 1
fi
for _ in \$(seq 1 120); do
  if grep -R "sync completed for $VOLUME" $ROOT_DIR/$VOLUME/logs/rclone-sync.log >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
if ! grep -R "sync completed for $VOLUME" $ROOT_DIR/$VOLUME/logs/rclone-sync.log >/dev/null 2>&1; then
  echo PRIV_SHARED_DB_SYNC_NO_SYNC_LOG node=\$node_id
  sed -n '1,120p' $ROOT_DIR/$VOLUME/logs/rclone-sync.log 2>/dev/null || true
  exit 1
fi
echo PRIV_SHARED_DB_SYNC_NODE_OK node=\$node_id role=\$(if test "\$node_id" = "$manager_node"; then echo primary; else echo replica; fi) rows=\$rows integrity=\$integrity
sleep 300
RUNNER_EOF

docker config rm "${STACK}-runner" >/dev/null 2>&1 || true
docker config create "${STACK}-runner" "$SMOKE/runner.sh" >/dev/null
cat > "$SMOKE/stack.yml" <<STACK_EOF
version: "3.8"
services:
  launcher:
    image: $LAUNCHER_IMAGE
    command: ["sh", "/cs-storage-priv-shared-db-sync-runner.sh"]
    configs:
      - source: runner
        target: /cs-storage-priv-shared-db-sync-runner.sh
        mode: 0555
    volumes:
      - type: bind
        source: /var/run/docker.sock
        target: /var/run/docker.sock
      - type: bind
        source: /run
        target: /hostrun
      - type: bind
        source: /mnt/cs_storage/vols
        target: /hostmnt
      - type: bind
        source: /var/log/cs-storage
        target: /hostlog
    deploy:
      mode: global
      restart_policy:
        condition: none
configs:
  runner:
    external: true
    name: ${STACK}-runner
STACK_EOF

docker stack deploy -c "$SMOKE/stack.yml" "$STACK" >/dev/null
service="${STACK}_launcher"
for _ in $(seq 1 360); do
  ok=$(timeout "$LOG_FETCH_TIMEOUT" docker service logs --raw --tail 1000 "$service" 2>/dev/null | awk '$1 == "PRIV_SHARED_DB_SYNC_NODE_OK" {n++} END {print n+0}')
  if test "$ok" -ge "$NODES_MIN"; then
    break
  fi
  sleep 1
done

timeout "$LOG_FETCH_TIMEOUT" docker service logs --raw --tail 2000 "$service" > "$SMOKE/logs.txt" 2>&1 || true
cat "$SMOKE/logs.txt"
ok=$(awk '$1 == "PRIV_SHARED_DB_SYNC_NODE_OK" {n++} END {print n+0}' "$SMOKE/logs.txt")
if test "$ok" -lt "$NODES_MIN"; then
  docker service ps "$service" --no-trunc || true
  echo SERVER_LOGS
  docker logs "$SERVER_CONTAINER" 2>&1 | sed -n '1,180p' || true
  echo "PRIV_SHARED_DB_SYNC_NOT_READY ok=$ok min=$NODES_MIN ready=$active_nodes image=$IMAGE driver=$DRIVER"
  exit 1
fi

verified=0
for node in $(awk '$1 == "PRIV_SHARED_DB_SYNC_NODE_OK" {for (i=1; i<=NF; i++) if ($i ~ /^node=/) {sub(/^node=/, "", $i); print $i}}' "$SMOKE/logs.txt" | sort -u); do
  rel="$REMOTE_ROOT/nodes/$node/$DB_NAME"
  for _ in $(seq 1 "$VERIFY_TIMEOUT"); do
    code=$(curl -sS -o "$SMOKE/remote-$node.db" -w '%{http_code}' --netrc-file "$NETRC" "$BASE_URL/$rel" || true)
    if test "$code" = "200"; then
      if docker run --rm --entrypoint sqlite3 -v "$SMOKE:/verify" "$IMAGE" "/verify/remote-$node.db" "PRAGMA integrity_check; SELECT COUNT(*) FROM events;" > "$SMOKE/remote-$node.out" 2>"$SMOKE/remote-$node.err"; then
        if grep -q '^ok$' "$SMOKE/remote-$node.out" && grep -q "^$ROWS$" "$SMOKE/remote-$node.out"; then
          verified=$((verified + 1))
          break
        fi
      fi
    fi
    sleep 1
  done
done
if test "$verified" -lt "$NODES_MIN"; then
  echo "PRIV_SHARED_DB_SYNC_REMOTE_VERIFY_FAILED verified=$verified min=$NODES_MIN remote_root=$REMOTE_ROOT rows=$ROWS"
  exit 1
fi

trap - EXIT
cleanup
docker config rm "${STACK}-runner" >/dev/null 2>&1 || true

echo "PRIV_SHARED_MULTI_DB_SYNC_WEBDAV_GLOBAL_SMOKE_OK nodes=$ok verified=$verified ready=$active_nodes image=$IMAGE driver=$DRIVER remote_root=$REMOTE_ROOT rows=$ROWS integrity=ok"
