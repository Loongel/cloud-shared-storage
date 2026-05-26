# CS-Storage

Cloud Shared Storage, abbreviated CSS, is a Go implementation scaffold for the cross-region Docker storage control plane described in `技术方案.v0.txt` and `技术方案.v1.txt`.

Current implemented components:

- `cs-storage-server`: central S-side auth, JWT-protected lightweight KV coordinator, and streaming reverse proxy.
- `cs-storage-daemon`: host-side C daemon receiving volume lifecycle RPCs over UDS, preparing guarded volume layout, maintaining configured daemon-managed mounts, and returning already-prepared mountpoints to Docker without owning storage routing in the plugin.
- `cs-storage-plugin`: Docker Volume V2 compatible thin proxy. It never mounts FUSE or starts heavy storage processes inside the plugin.
- `cs-storage-admin`: operator CLI. It can list backups and restore with `.BAK.<timestamp>` protection.
- `cs-storage-router`: Go-FUSE router for `engine=auto`; it can also run `-classify` to validate routing decisions without mounting.

## S-side Gateway

Required environment:

- `CS_NODE_SECRET_KEY`: pre-shared HMAC key for node auth and JWT signing.
- `CS_BACKEND_URL`: real WebDAV/S3 HTTP-compatible backend base URL.

Optional environment:

- `CS_SERVER_ADDR`: listen address, default `:18080`.
- `CS_BACKEND_AUTH_HEADER`: backend `Authorization` header injected after stripping the node JWT.
- `CS_BACKEND_USER` / `CS_BACKEND_PASSWORD`: optional WebDAV Basic Auth source when `CS_BACKEND_AUTH_HEADER` is not set.
- `CS_TOKEN_TTL`: token lifetime, default `12h`.
- `CS_SANDBOX_PREFIX`: sandbox prefix, default `/nodes`.
- `CS_KV_PATH`: optional JSON persistence path for the lightweight coordinator KV.
- `CS_COORDINATOR_TOKEN`: optional Consul-compatible token accepted through `X-Consul-Token` or `?token=` for LiteFS clients.
- `CS_PUBLIC_URL`: optional externally reachable gateway URL returned from `/auth` as the node rclone endpoint; if unset, the server infers it from forwarded headers and the request host.

Flow:

1. A C node calls `POST /auth` with `node_id`, `timestamp`, and an HMAC signature over `node_id + "\n" + timestamp`.
2. The server returns a signed JWT containing the node sandbox path and the gateway endpoint the node should use for rclone.
3. Rclone sends `Authorization: Bearer <jwt>` to the gateway endpoint.
4. The gateway validates the JWT, strips it, injects the real backend auth header, and rewrites every backend path under the sandbox from the JWT. Client-supplied attempts to target another node path are not trusted.

The S side also exposes JWT-protected coordinator endpoints for lease/election integration. `/v1/kv/<key>` supports a Consul-style JSON KV API, `?raw` reads, and `?acquire=<session>` / `?release=<session>` lock operations. `/v1/session/create`, `/v1/session/renew/<id>`, `/v1/session/info/<id>`, and `/v1/session/destroy/<id>` provide a minimal Consul session subset for LiteFS-style leases. Set `CS_KV_PATH` to persist KV values as a local JSON file. A complete Consul/Etcd protocol remains future work.

## C-side Daemon

Common environment:

- `CS_DAEMON_SOCKET`: UDS path, default `/run/cs-storage.sock`.
- `CS_ROOT_DIR`: volume root, default `/mnt/cs_storage/vols`.
- `CS_STATE_PATH`: JSON state path, default `$CS_ROOT_DIR/.state/volumes.json`.
- `CS_AUDIT_LOG`: daemon lifecycle audit log path, default next to state as `$CS_ROOT_DIR/.state/audit.jsonl`.
- `CS_SERVER_URL`: S-side gateway URL used for node auth and rclone WebDAV access.
- `CS_NODE_ID`: unique node identity embedded into JWT claims.
- `CS_NODE_SECRET_KEY`: pre-shared HMAC key matching the S side.
- `CS_RCLONE_ENDPOINT`: optional WebDAV endpoint override for rclone; when empty, the daemon uses the endpoint returned by `/auth`, then falls back to `CS_SERVER_URL`.
- `CS_RCLONE_BINARY`: rclone binary path, default `rclone`.
- `CS_RCLONE_RC_ADDR`: rclone RC URL, for example `http://127.0.0.1:5572`.
- `CS_RCLONE_RC_USER` / `CS_RCLONE_RC_PASSWORD`: optional rclone RC basic auth.
- `CS_RCLONE_VFS_CACHE_MODE`: rclone VFS cache mode, default `writes`.
- `CS_RCLONE_VFS_WRITE_BACK`: optional rclone write-back delay.
- `CS_RCLONE_VFS_CACHE_MAX_SIZE`: optional rclone VFS cache size cap, for example `10G`; passed as `--vfs-cache-max-size`.
- `CS_RCLONE_EXTRA_ARGS`: optional extra rclone mount/sync flags.
- `CS_RCLONE_SYNC_INTERVAL`: enable shared multi-write periodic `rclone sync` when set, for example `5m`. Disabled by default.
- `CS_RCLONE_SYNC_SOURCE`: optional source template for periodic sync; supports `{volume}`. Defaults to the volume mountpoint.
- `CS_RCLONE_SYNC_TARGET`: optional rclone target template for periodic sync; supports `{volume}`. Defaults to the gateway remote root for that volume.
- `CS_GOCRYPTFS_PASSWORD`: passphrase required when `cs.crypt=true`.
- `CS_GOCRYPTFS_BINARY`: gocryptfs binary path, default `gocryptfs`.
- `CS_GOCRYPTFS_EXTRA_ARGS`: optional extra gocryptfs flags.
- `CS_GLUSTER_REMOTE`: GlusterFS remote for `cs.engine=static`, for example `host:/volume`.
- `CS_GLUSTER_BINARY`: GlusterFS mount helper, default `mount.glusterfs`.
- `CS_GLUSTER_EXTRA_ARGS`: optional GlusterFS mount flags.
- `CS_LITEFS_BINARY`: LiteFS binary path, default `litefs`.
- `CS_LITEFS_CONFIG`: optional existing LiteFS config; if empty, daemon writes one under the volume config directory.
- `CS_LITEFS_HTTP_ADDR`: generated LiteFS HTTP address, default `:20202`.
- `CS_LITEFS_LEASE_TYPE`: generated LiteFS lease type, default `static`.
- `CS_LITEFS_ADVERTISE_URL`: required when daemon generates LiteFS config; peers use it to reach this node.
- `CS_LITEFS_CONSUL_URL`: optional generated LiteFS Consul URL.
- `CS_LITEFS_CONSUL_KEY`: optional LiteFS Consul KV key; defaults to `cs-storage/litefs/<volume>`.
- `CS_LITEFS_CONSUL_TOKEN`: optional Consul-compatible token passed to LiteFS as `CONSUL_HTTP_TOKEN`.
- `CS_LITEFS_CONSUL_TTL`: generated LiteFS Consul session TTL, default `10s`.
- `CS_LITEFS_CONSUL_LOCK_DELAY`: generated LiteFS Consul lock delay, default `1s`.
- `CS_LITEFS_HOSTNAME`: optional LiteFS lease hostname override.
- `CS_LITEFS_PROMOTE`: generated LiteFS promote flag, default `false`.
- `CS_LITEFS_CANDIDATE`: generated LiteFS candidate flag, default `true`.
- `CS_KOPIA_REPOSITORY`: legacy repository hint for `cs.backup=auto`; use `CS_KOPIA_CONFIG_PATH` for a real connected Kopia repository config.
- `CS_KOPIA_CONFIG_PATH`: Kopia config file created by `kopia repository create|connect ... --config-file`; required for real Kopia snapshots unless the daemon environment already provides `KOPIA_CONFIG_PATH`.
- `CS_KOPIA_PASSWORD`: optional Kopia repository password.
- `CS_KOPIA_BINARY`: Kopia binary path, default `kopia`.
- `CS_KOPIA_EXTRA_ARGS`: optional Kopia snapshot flags.
- `CS_KOPIA_POLICY_ARGS`: optional Kopia `policy set` retention flags applied to the volume mountpoint before each snapshot, for example `--keep-latest=24 --keep-daily=7`.
- `CS_KOPIA_SNAPSHOT_INTERVAL`: interval for `cs.backup=auto` periodic Kopia snapshots, default `1h`; set `0` to keep only final snapshots on unmount/remove.
- `CS_ROUTER_BINARY`: `engine=auto` router binary path, default `cs-storage-router`.
- `CS_ROUTER_EXTRA_ARGS`: optional extra router flags.
- `CS_ENABLE_CHATTR`: optional immutable-root guard.
- `CS_RECOVER_MOUNTS`: on daemon startup, try to restart volumes that still have stored mount references; default `false`, which clears stale references.
- `CS_MANAGED_VOLUMES`: semicolon-separated daemon-managed volumes, for example `app:cs.mode=shared,cs.write=multi,cs.engine=sqlite,cs.crypt=false;cache:cs.crypt=false`. The daemon creates, mounts, and keeps these ready before Docker asks for them. Destructive `flush` is ignored in this steady-state declaration; it is honored only on explicit create/remove requests. `CS_PREMOUNT_VOLUMES` is accepted only as a backward-compatible alias.
- `CS_MANAGED_ENSURE_INTERVAL`: background reconciliation interval for `CS_MANAGED_VOLUMES`, default `30s`.
- Any string environment setting can also be supplied as `<KEY>_FILE`; direct `<KEY>` values take precedence. This is intended for Docker secrets or 0600 env-file wrappers so credentials do not need to appear in container inspect output.

Implemented volume options:

The daemon treats driver opts and explicit plugin/daemon `Labels` payloads as request-scoped inputs, with opts taking precedence. These values are used to choose the runtime pipeline and backend path for that request, but they are not persisted in daemon metadata. `flush` is accepted only from opts; label-sourced `flush` is rejected because it is destructive. On hd01, Docker Engine did not expose `docker volume create --label ...` values to the VolumeDriver callback or Docker volume API for this plugin, so `cs-storage-admin render-compose` provides the verified Stack/Compose transform: it copies supported top-level volume labels into `driver_opts`, where Docker reliably passes them to the VolumeDriver. For deployment, use `cs-storage-admin deploy-stack -in stack.yml -stack <name>` so the transform is applied before `docker stack deploy`.

- `cs.mode=private|shared`, default `private`.
- `cs.write=single|multi`, default `single`.
- `cs.engine=auto|static|sqlite`, default `auto`.
- `cs.crypt=true|false`, default `true`.
- `cs.backup=none|auto`, default `none`.
- `flush=true|false`, default `false`.

The daemon contains the auth client, rclone WebDAV config/mount/sync argument builders, process supervisor, mount-readiness checks, and gocryptfs initialization needed for realtime private/shared-single volumes. Nodes request both JWTs and the preferred gateway endpoint from `cs-storage-server`; the daemon then writes rclone config from that response unless `CS_RCLONE_ENDPOINT` explicitly overrides it. FUSE-style mount waits now check the managed child process state, so early rclone/gocryptfs/LiteFS/router exits are reported immediately instead of being hidden as generic mount-readiness timeouts. JWT is passed to rclone at runtime with `--header "Authorization: Bearer <token>"` instead of being stored in the config file. rclone is started with RC enabled when `CS_RCLONE_RC_ADDR` is set; on each Docker `Mount` for realtime rclone-backed volumes, the daemon calls non-destructive `vfs/forget` before returning the mountpoint so container startup sees a fresh remote directory view. Destructive `flush` remains restricted to explicit create/remove opts.

For daemon-managed volumes, `CS_MANAGED_VOLUMES` starts a background reconciliation loop inside `cs-storage-daemon`: it creates the guarded layout, starts and maintains the required rclone/gocryptfs/LiteFS/Gluster/router processes from daemon-owned config, records a daemon mount reference, and leaves the Docker VolumeDriver path as a thin fast path to the already-ready mountpoint. Docker `Remove` keeps daemon-managed volumes alive by default; an explicit create/remove request with `flush=true` is required for the one-time destructive cleanup. For shared multi-write volumes, setting `CS_RCLONE_SYNC_INTERVAL` starts a daemon-managed periodic sync loop after Gluster/LiteFS/router mount readiness. Each sync cycle requests a fresh JWT before running `rclone sync`, so token expiration does not break long-running mounts. This path has hd01 build/unit coverage; formal real-backend cluster write validation is complete on all 4 Ready nodes; longer soak remains a hardening exercise.

## Observability

Both long-running services expose Prometheus text metrics at `/metrics`. The daemon also writes JSONL lifecycle audit records for create/remove/mount/unmount success and failure events to `CS_AUDIT_LOG`.

`cs-storage-server` publishes gateway counters for issued and rejected auth requests, proxy requests, proxy JWT rejections, KV requests, KV JWT rejections, and invalid KV keys.

`cs-storage-daemon` exposes `/healthz` as liveness and `/readyz` as readiness; readiness returns 503 when a desired managed child process is not running. It publishes daemon gauges for configured volumes, mounted volumes, active mount references, managed child processes, desired managed processes, and unhealthy desired processes, plus counters for child process starts, exits, restart attempts, restart successes, and restart failures. Option-derived counts are intentionally not reconstructed from metadata because volume options are request-scoped. The daemon endpoint is served on the same Unix socket as the lifecycle API.

## Docker Volume Plugin

Environment:

- `CS_PLUGIN_SOCKET`: Docker plugin UDS path, default `/run/docker/plugins/css.sock`; Docker sees this as the `css` VolumeDriver.
- `CS_DAEMON_SOCKET`: daemon UDS path, default `/run/cs-storage.sock`.
- `CS_PLUGIN_TIMEOUT`: proxy timeout, default `5s`.
- `CS_PLUGIN_SCOPE`: Docker capability scope, default `local`.

The plugin implements the Docker VolumeDriver endpoints directly with the Go standard library and forwards lifecycle calls to the daemon.

## Restore CLI

The admin tool can list remote backup directories and restore either an exact backup source or the latest backup under a per-volume backup root. Restore is intentionally conservative: if the target exists, it is renamed before any remote data is copied back:

```sh
cs-storage-admin backups -source remote:backups
```

```sh
cs-storage-admin restore -source remote:backups/my-volume/20260522-010000 -volume my-volume
```

Latest backup under a volume root:

```sh
cs-storage-admin restore -source-root remote:backups -latest -volume my-volume
```

Equivalent explicit target form:

```sh
cs-storage-admin restore -source remote:backups/my-volume/20260522-010000 -target /mnt/cs_storage/vols/my-volume/mount
```

Default backup naming:

```text
/mnt/cs_storage/vols/my-volume/mount.BAK.20260521-163000
```

Useful flags:

- `-dry-run`: print the restore plan without renaming or copying.
- `-rollback-on-fail`: if rclone fails, remove the new target and rename the `.BAK.<timestamp>` directory back.
- `-rclone-config`: pass an explicit rclone config.
- `-rclone-args`: append extra rclone args.
- `-timeout`: cap restore time, for example `2h`.

## Deployment Artifacts

This repository now includes production-oriented deployment scaffolding:

- `Dockerfile`: builds a single image containing all CS-Storage binaries plus the runtime toolchain used by the daemon paths: rclone, gocryptfs, GlusterFS client/server, sqlite3, FUSE userspace tools, LiteFS copied from `flyio/litefs:0.5`, and Kopia copied from `kopia/kopia:0.23`.
- `deploy/systemd/*.service`: systemd units for the S-side gateway, C-side daemon, and Docker VolumeDriver thin proxy.
- `deploy/env/*.env.example`: secret-free environment templates; copy them to `/etc/cs-storage/*.env` and fill secrets outside git.
- `deploy/install/install.sh`: installs prebuilt binaries from `bin/`, systemd units, first-run env templates, the `cs-storage` system service user, and server-writable state/log directories.
- `scripts/cs-storage-build-deb.sh`: builds a release `.deb` containing the five `cs-storage-*` binaries, systemd units, env examples, and the node installer.
- `scripts/cs-storage-systemd-node-install.sh`: formal node installer for host systemd deployment. It can install a package from `--deb-url`/`--deb`, or use local `--bin-dir` only for development and recovery.
- `.github/workflows/release.yml`: GitHub Actions workflow that builds the `.deb`, publishes a checksum artifact, and uploads both files to the GitHub Release when a `v*` tag is pushed.
- `deploy/stack/cs-storage-server.yml`: Swarm Stack template for the S-side gateway.
- `deploy/stack/cs-storage-daemon-global.yml` and `deploy/stack/cs-storage-plugin-global.yml`: legacy Swarm validation templates. They are not the formal production client runtime; the formal client runtime is the host `cs-storage-daemon.service` plus `cs-storage-plugin.service`.
- `deploy/stack/example-app.yml`: example app volume declaration using labels that `cs-storage-admin render-compose` converts into `driver_opts`.
- `deploy/stack/css-scenario-test.yml`: post-install validation stack for the host `css` driver. It is a repository test artifact, not part of the production `.deb`; it mounts real CSS volumes on labelled nodes and pairs with `scripts/css-scenario-test-deploy.sh` / `scripts/css-scenario-test-report.sh` to produce pass/fail reports with direct WebDAV backend checks.

## Host Systemd Install

Formal production deployment uses host systemd services, not long-running CS-Storage runtime containers:

- `cs-storage-server.service` listens on the NetBird `wt0` IPv4 address by default, using the first free port in `18080-18100`.
- `cs-storage-daemon.service` owns `/run/cs-storage.sock` and host mounts under `/mnt/cs_storage/vols`.
- `cs-storage-plugin.service` owns `/run/docker/plugins/css.sock` for the Docker `css` VolumeDriver.

Build the release package:

```sh
./scripts/cs-storage-build-deb.sh --version 0.1.1
```

Publish through GitHub Actions by pushing a tag:

```sh
git tag v0.1.1
git push origin main v0.1.1
```

For normal installs, use the role-specific one-command wrappers.

Server only, for a dedicated gateway node. Required: backend URL and backend auth only. If you do not pass `--node-secret`, the script generates `/etc/cs-storage/secrets/node_secret` and prints a ready-to-run client install command containing that same secret.

```sh
curl -fsSL https://raw.githubusercontent.com/Loongel/cloud-shared-storage/main/scripts/css-install-server.sh \
  | sudo sh -s -- \
  --backend-url https://rausu.infini-cloud.net/dav/ \
  --backend-user '<webdav-user>' \
  --backend-password '<webdav-password>'
```

After a server/all install, the script prints a filled `CSS_CLIENT_INSTALL_COMMAND` using the NetBird FQDN from `wt0` when available. It also saves the same command at `/etc/cs-storage/client-install-command.sh` with mode `0600`.

Client only, for an application node. Required: server URL and the server's same `node_secret`.

```sh
curl -fsSL https://raw.githubusercontent.com/Loongel/cloud-shared-storage/main/scripts/css-install-client.sh \
  | sudo sh -s -- \
  --server-url http://<server-netbird-fqdn-or-wt0-ip>:<server-port> \
  --node-secret '<node-secret-from-server-output>'
```

`node_secret` is not the node id. The node id defaults to the NetBird FQDN from
`netbird status`, then falls back to the host name, and can be overridden with
`--node-id`. `node_secret` is the shared cluster authentication secret generated
by the server/all installer. The server-printed client command embeds this value
so a client node does not need a separate file-copy step. Treat that command as
a secret because it grants access to the CSS server.

Server plus client on the same node. Required: backend URL and backend auth only. The local client uses the local server URL automatically.

```sh
curl -fsSL https://raw.githubusercontent.com/Loongel/cloud-shared-storage/main/scripts/css-install-all.sh \
  | sudo sh -s -- \
  --backend-url https://rausu.infini-cloud.net/dav/ \
  --backend-user '<webdav-user>' \
  --backend-password '<webdav-password>'
```

The lower-level installer remains available for advanced automation:

```sh
curl -fsSL https://raw.githubusercontent.com/Loongel/cloud-shared-storage/main/scripts/cs-storage-systemd-node-install.sh -o /tmp/cs-storage-install.sh
ACK_INSTALL_HOST_DEPS=yes \
sh /tmp/cs-storage-install.sh \
  --deb-url https://github.com/Loongel/cloud-shared-storage/releases/download/v0.1.1/cs-storage_0.1.1_amd64.deb \
  --role all \
  --driver-name css \
  --server-url http://127.0.0.1:18080 \
  --backend-url <webdav-or-s3-http-url> \
  --node-secret-file /etc/cs-storage/secrets/node_secret \
  --backend-user-file /etc/cs-storage/secrets/backend_user \
  --backend-password-file /etc/cs-storage/secrets/backend_password \
  --gocryptfs-password-file /etc/cs-storage/secrets/gocryptfs_password \
  --node-id "$(hostname)" \
  --install-deps \
  --enable-now
```

Use `--role server` on a gateway-only node and `--role client` on client-only nodes. Use `--backend-auth-header` or `--backend-auth-header-file` instead of user/password when the backend requires a complete authorization header. Inline values such as `--backend-user`, `--backend-password`, `--backend-auth-header`, `--node-secret`, and `--gocryptfs-password` are copied into root-owned files under `/etc/cs-storage/secrets`; file arguments are the safer form for automation because inline secrets can appear in shell history or process listings. Pass `--bind-interface <iface>`, `--server-addr <addr:port>`, or `--public-url <url>` only when you intentionally do not want the default NetBird `wt0` binding and URL.

### Secret Safety

The one-command wrappers intentionally avoid surprising secret changes:

- `node_secret` authenticates clients to the server. It is generated only during first server/all install if absent. Client-only installs never generate it; they require the exact same file/value from the server.
- `gocryptfs_password` protects encrypted volume contents. It is generated only during first client/all install if absent. Changing it after encrypted data exists makes that old encrypted data unreadable.
- Existing secret files are reused on repeat installs.
- Passing a different secret value/file for an existing secret is refused by default. To rotate intentionally, pass `--force-secret-update`; the old file is backed up as `*.BAK.<timestamp>` first.
- Server/all install output prints a client bootstrap command containing `node_secret` by default, and saves it to `/etc/cs-storage/client-install-command.sh` with mode `0600`. Pass `--no-print-client-secret` if you want to suppress this convenience output. Back up `/etc/cs-storage/secrets/node_secret` and `/etc/cs-storage/secrets/gocryptfs_password` through your own secure channel.

See `docs/install-guide.md` for scenario commands, parameter details, repeat
install behavior, and common failure handling.

## Formal Scenario Stack Test

After installing the host systemd services, validate the delivered `css` driver
with the scenario stack:

```sh
sudo sh scripts/css-scenario-test-deploy.sh --clean --profile smoke --current-node
```

After installing client services on every target Swarm node:

```sh
sudo sh scripts/css-scenario-test-deploy.sh --clean --profile full --all-ready-nodes
```

The stack only schedules on nodes labelled `css.test.enabled=true`. The deploy
script applies that label to selected nodes, renders the requested scenario
matrix, then writes `results.tsv`, `controls.tsv`, `report.md`, service logs,
and the rendered Stack under `reports/css-scenario-<run-id>/`. `full` covers all
36 valid option combinations plus negative/control checks; `smoke` is only a
fast local subset. See `docs/scenario-test-guide.md` for the profile details.
Use `--clear-labels` if you want the script to remove its temporary
`css.test.*` node labels after reporting.

## Build on hd01

Per project instruction, do not compile or test locally. Once `ssh hd01` works, run from a copy of this directory on hd01:

```sh
./scripts/hd01-build.sh
./scripts/hd01-gateway-stream-smoke.sh
./scripts/hd01-gateway-authz-smoke.sh
./scripts/hd01-gateway-webdav-smoke.sh
./scripts/hd01-chattr-guard-smoke.sh
./scripts/hd01-router-smoke.sh
./scripts/hd01-router-sqlite-smoke.sh
./scripts/hd01-litefs-daemon-global-smoke.sh
./scripts/hd01-litefs-consul-smoke.sh
./scripts/hd01-litefs-consul-global-smoke.sh
./scripts/hd01-litefs-consul-remote-write-smoke.sh
./scripts/hd01-litefs-consul-stress-smoke.sh
./scripts/hd01-shared-multi-sync-webdav-smoke.sh
./scripts/hd01-shared-multi-db-sync-webdav-smoke.sh
# optional safer credential loading for the direct DB sync smoke:
# CS_WEBDAV_ENV_FILE=/tmp/cs-storage-webdav.env ./scripts/hd01-shared-multi-db-sync-webdav-smoke.sh
./scripts/hd01-daemon-managed-volume-smoke.sh
./scripts/hd01-gluster-daemon-global-smoke.sh
./scripts/hd01-gluster-replica-smoke.sh
./scripts/hd01-docker-plugin-smoke.sh
./scripts/hd01-compose-render-smoke.sh
./scripts/hd01-consul-coordinator-smoke.sh
./scripts/hd01-restore-admin-smoke.sh
./scripts/hd01-kopia-backup-smoke.sh
./scripts/hd01-deploy-artifacts-smoke.sh
./scripts/hd01-daemon-stack-smoke.sh
./scripts/hd01-swarm-image-load-smoke.sh
./scripts/hd01-daemon-global-run-smoke.sh
./scripts/hd01-plugin-daemon-global-smoke.sh
./scripts/hd01-runtime-image-smoke.sh
./scripts/hd01-server-stack-smoke.sh
./scripts/hd01-stack-smoke.sh
./scripts/hd01-cluster-preflight.sh
./scripts/hd01-cluster-deps-rollout.sh  # dry-run by default; requires APPLY=1 ACK_INSTALL_HOST_DEPS=yes to modify hosts
./scripts/hd01-acceptance-audit.sh
./scripts/hd01-swarm-fuse-device-smoke.sh
./scripts/hd01-host-daemon-webdav-workload-smoke.sh
./scripts/hd01-privileged-daemon-webdav-global-smoke.sh
./scripts/hd01-webdav-env-run.sh ./scripts/hd01-privileged-shared-multi-db-sync-webdav-global-smoke.sh < /tmp/cs-storage-webdav.env

./scripts/hd01-production-path-prepare.sh
./scripts/hd01-production-path-preflight.sh
./scripts/hd01-production-path-global-smoke.sh
./scripts/hd01-production-driver-smoke.sh
./scripts/hd01-production-secrets-preflight.sh
./scripts/hd01-production-stack-plan.sh
./scripts/hd01-production-readiness-gate.sh
./scripts/hd01-production-secrets-bootstrap.sh  # dry-run by default; requires APPLY=1 ACK_WRITE_PRODUCTION_SECRETS=yes to write /etc/cs-storage env files
```

## Production Status And Boundaries

The formal delivery target is host systemd deployment: `cs-storage-server.service`, `cs-storage-daemon.service`, and `cs-storage-plugin.service` installed on the node by `scripts/cs-storage-systemd-node-install.sh`, with binaries supplied by a GitHub Release `.deb`. Earlier Swarm/container launcher evidence is retained as historical validation only; it is not the formal production runtime. The remaining boundary is destructive failure injection for Gluster/LiteFS partitions and split-brain behavior, which is intentionally excluded from the live hd01 cluster and belongs in a disposable lab.

- Realtime rclone/gocryptfs startup now distinguishes early child-process exit from slow mount readiness and releases parent-side log file descriptors after process start. Long-running daemon child processes now opt into ProcessManager restart supervision for unexpected exits; restart attempts keep retrying across temporary start failures until explicit Stop/unmount cancels the desired state, including pending restarts. `/readyz` reports desired managed processes that are not currently running, and metrics expose desired/unhealthy process gauges. This has hd01 unit coverage plus daemon-managed smoke coverage. A single-node host-daemon real WebDAV workload smoke now validates the intended C-side host FUSE path end-to-end on hd01. Additional hardening outside this delivery includes deeper stale-state recovery and long-running restart policy validation under real workloads.
- GlusterFS/LiteFS orchestration has a first pass; shared multi periodic `rclone sync` now has hd01 build/unit coverage, and the hd01-built runtime image now contains LiteFS and Kopia in addition to rclone/gocryptfs/Gluster/sqlite/FUSE tools. A Swarm global LiteFS smoke now starts node-local privileged daemon/plugin containers on all 4 Ready nodes, creates `shared+multi+sqlite` volumes, writes SQLite rows through real LiteFS FUSE mounts, and verifies `PRAGMA integrity_check`. The LiteFS Consul smokes now run real LiteFS against `cs-storage-server` as the Consul-compatible coordinator with `X-Consul-Token`; the global variant elects hd01 as primary, replicates a SQLite row to the other 3 Ready nodes, and verifies `PRAGMA integrity_check` on every node. A Swarm global Gluster smoke now starts node-local Gluster server, daemon, and plugin containers on all 4 Ready nodes, creates `shared+multi+static` volumes, writes a file through a real Gluster FUSE mount, reads it back, and verifies the daemon-managed Gluster log path. A separate Gluster replica smoke now creates a real `replica 3 arbiter 1` volume across three Ready nodes using Swarm `Status.Addr` peer addresses, mounts that same volume from all 4 Ready nodes, has every node write its own file, and verifies every client sees all 4 files. `cs.backup=auto` now has a real Kopia filesystem-repository smoke that creates a connected repository config, verifies a daemon-managed periodic snapshot before removal, restores the snapshot, and compares payload bytes. Kopia retention can be configured with `CS_KOPIA_POLICY_ARGS`, which runs `kopia policy set` before each snapshot and has hd01 unit coverage. A host-daemon shared-multi periodic sync smoke now validates daemon-managed `rclone sync` from a configured shared-multi source directory to the real WebDAV gateway sandbox after creating a `shared+multi+sqlite` volume and writing through LiteFS. A dedicated direct LiteFS-FUSE database-file sync smoke now validates daemon-managed periodic `rclone sync` directly from a LiteFS FUSE mountpoint to the real WebDAV gateway sandbox, downloads the synced `main.db`, and verifies `PRAGMA integrity_check` plus the expected row count. The script can load WebDAV credentials from `CS_WEBDAV_ENV_FILE` under `/tmp`, `/run/secrets`, or `/etc/cs-storage` so secrets do not need to appear in the command line. The global shared-multi WebDAV DB sync smoke starts `cs-storage-server` from the runtime image on the manager instead of requiring a host Go toolchain. Multi-node production cluster write validation is complete through the formal driver and real WebDAV GET checks; realtime rclone FUSE mounts inside Swarm Stack services are currently blocked because hd01 Docker Stack ignores the Compose `devices` field and the probe containers cannot see `/dev/fuse`. `scripts/hd01-cluster-preflight.sh` now checks host prerequisites across Ready Swarm nodes through an attachable overlay collector instead of relying on partial Docker service log aggregation. It emits `missing.tsv`, `packages.tsv`, `manual.tsv`, `logged-nodes.tsv`, `collected-logs.txt`, a review-only `install-plan.sh`, and `verify-after-install.sh`; earlier dry-run output identified missing host tools before rollout. After guarded rollout, all 4 Ready nodes have the required host tools and strict cluster preflight reports CLUSTER_PREFLIGHT_OK. `scripts/hd01-cluster-deps-rollout.sh` now provides a guarded Swarm global rollout path for these host prerequisites: it is dry-run by default, validates the runtime image and Ready-node count, prints the preflight table, and refuses host changes unless both `APPLY=1` and `ACK_INSTALL_HOST_DEPS=yes` are set. The guarded dry-run and missing-ACK refusal are verified on hd01; the guarded host dependency rollout has been applied and strict preflight is clean. Image-backed Swarm launcher smokes now cover non-disruptive Gluster happy-path consistency, LiteFS Consul lease/replication happy-path consistency, and a four-node LiteFS remote-write workflow where every Ready node writes through `litefs run -promote` and all nodes verify the same SQLite row count and `PRAGMA integrity_check`. Additional hardening outside this delivery includes longer-duration SQLite soak testing, deeper health supervision, and disposable-lab destructive Gluster failure-mode validation.
- Go-FUSE dynamic router has real FUSE smoke coverage plus SQLite WAL/concurrent-write integrity coverage. It now also has unit coverage for common POSIX passthrough operations: chmod/truncate/mtime via Setattr, symlink/readlink, same-engine hardlinks, and cross-engine hardlink rejection with `EXDEV`. Additional hardening outside this delivery is larger stress testing.
- Coordinator now has a JWT-protected minimal Consul KV/session subset for LiteFS-style leases, including TTL expiry, lock release, CAS, Consul token auth, and `LockDelay` JSON compatibility required by LiteFS renew/info calls. Additional hardening outside this delivery is broader Consul/Etcd protocol compatibility.
- Native Docker `--label` propagation to VolumeDriver remains unavailable on hd01's Docker path, but Stack/Compose labels now have a verified deploy path via `cs-storage-admin deploy-stack`, which renders labels into `driver_opts` before invoking `docker stack deploy`. Systemd units, env templates, Dockerfile, `.deb` packaging, and the host node installer now exist. The formal service path uses `/run/cs-storage.sock`, `/run/docker/plugins/css.sock`, `/mnt/cs_storage/vols`, and `/var/log/cs-storage` directly on the host. The older Swarm launcher and Stack templates remain useful for non-production smoke tests and historical evidence, but they are not the formal runtime path.
- Real cross-node LiteFS Consul lease/replication happy-path acceptance and a non-disruptive four-node SQLite remote-write workflow are now covered on hd01. Real Gluster replica/arbiter happy-path consistency is also covered; destructive network-partition, node-offline, firewall, route, `docker network disconnect`, Swarm node drain, `tc/netem`, and split-brain induction tests must not be run on the live hd01 cluster and still require a separate disposable lab.

## Verified on hd01

The current source was validated on `hd01` from synced source under `/tmp/cs-storage-work-current`. Because the hd01 host PATH does not currently provide `go`, Go unit tests and command builds are run inside `golang:1.22-bookworm` on hd01 with `--network host`; the runtime image build also uses `docker build --network host` when container DNS cannot resolve external mirrors. This does not change host networking configuration.

```text
docker run --rm --network host -v "$PWD:/src:ro" -w /src golang:1.22-bookworm sh -lc "/usr/local/go/bin/go test ./..."
# daemon process lifecycle coverage includes early-exit mount readiness failures, log capture, restart supervision, restart retry after temporary start failure, process supervision metrics, readyz desired-process health, Stop-cancels-restart, and JSONL audit records
# rclone mount argument coverage includes runtime bearer headers, sanitized remotes, --cache-dir, --vfs-write-back, --vfs-cache-max-size, and Docker Mount-time non-destructive vfs/forget
# routerfuse coverage includes Setattr chmod/truncate/mtime, symlink/readlink, same-engine hardlink, and cross-engine EXDEV hardlink rejection
# kopia backup coverage includes periodic snapshots and policy-set retention arguments before snapshot create
docker run --rm --network host -v "$PWD:/src:ro" -w /src golang:1.22-bookworm sh -lc "/usr/local/go/bin/go build -buildvcs=false ./cmd/cs-storage-server ./cmd/cs-storage-daemon ./cmd/cs-storage-plugin ./cmd/cs-storage-admin ./cmd/cs-storage-router"
docker build --network host -t cs-storage:hd01-smoke .
HD01_DOCKER_BUILD_OK image=cs-storage:hd01-smoke network=host
RUNTIME_IMAGE_SMOKE_OK image=cs-storage:hd01-smoke litefs=v0.5.14 kopia=0.23.0
ROUTER_SMOKE_OK
ROUTER_SQLITE_SMOKE_OK rows=400 integrity=ok image=cs-storage:hd01-smoke
ROUTER_SQLITE_SMOKE_OK rows=4000 writers=8 rows_per_writer=500 integrity=ok image=cs-storage:hd01-smoke
LITEFS_DAEMON_GLOBAL_SMOKE_OK nodes=4 ready=4 image=cs-storage:hd01-smoke driver=cs-storage-litefs-smoke rows_per_node=20 integrity=ok
LITEFS_CONSUL_SMOKE_OK image=cs-storage:hd01-smoke rows=1 integrity=ok coordinator=cs-storage-server nodes=2
LITEFS_CONSUL_GLOBAL_SMOKE_OK nodes=4 ready=4 image=cs-storage:hd01-smoke coordinator=http://100.106.169.196:18182 primary=hd01 rows=1 integrity=ok
LITEFS_CONSUL_REMOTE_WRITE_SMOKE_OK nodes=4 ready=4 image=cs-storage:hd01-smoke coordinator=http://100.106.169.196:18183 rows=33 writes_per_node=8 integrity=ok
LITEFS_CONSUL_STRESS_SMOKE_OK nodes=4 log_ok=3 ready=4 image=cs-storage:hd01-smoke coordinator=http://100.106.169.196:18193 primary=hd01 rows=512 integrity=ok
LITEFS_CONSUL_STRESS_SMOKE_OK nodes=4 log_ok=3 ready=4 image=cs-storage:hd01-smoke coordinator=http://100.106.169.196:18193 primary=hd01 rows=2048 integrity=ok
GLUSTER_DAEMON_GLOBAL_SMOKE_OK nodes=4 ready=4 image=cs-storage:hd01-smoke driver=cs-storage-gluster-smoke file=static.txt
GLUSTER_REPLICA_SMOKE_OK clients=4 ready=4 bricks=3 arbiter=1 image=cs-storage:hd01-smoke volume=gv_cs_replica_smoke remote=100.106.169.196:/gv_cs_replica_smoke
DOCKER_PLUGIN_SMOKE_OK
DOCKER_PLUGIN_FAILFAST_SMOKE_OK elapsed=5s
COMPOSE_RENDER_SMOKE_OK
DEPLOY_STACK_SMOKE_OK
CONSUL_COORDINATOR_SMOKE_OK
RESTORE_ADMIN_SMOKE_OK
KOPIA_BACKUP_SMOKE_OK volume=kopia-backup-vol image=cs-storage:hd01-smoke repo=filesystem periodic=ok policy=ok snapshots=1
DEPLOY_ARTIFACTS_SMOKE_OK
DAEMON_STACK_SMOKE_OK image=cs-storage:hd01-smoke
IMAGE_LOAD_SMOKE_OK nodes=4 ready=4 image=cs-storage:hd01-smoke loader=docker:27-cli server=busybox:1.36
IMAGE_LOAD_LOGS_PARTIAL loaded=3 completed=4 min=4 image=cs-storage:hd01-smoke
DAEMON_GLOBAL_LOGS_PARTIAL ready_logs=2 running=4 min=4 image=cs-storage:hd01-smoke
DAEMON_GLOBAL_RUN_SMOKE_OK nodes=4 ready_logs=2 swarm_ready=4 image=cs-storage:hd01-smoke
PLUGIN_DAEMON_GLOBAL_LOGS_PARTIAL ok=2 running=4 min=4 image=cs-storage:hd01-smoke tester=docker:27-cli
PLUGIN_DAEMON_GLOBAL_SMOKE_OK nodes=4 ready=4 image=cs-storage:hd01-smoke tester=docker:27-cli driver=cs-storage-swarm-smoke
SERVER_STACK_SMOKE_OK image=cs-storage:hd01-smoke port=18080
CHATTR_GUARD_SMOKE_OK
GATEWAY_STREAM_SMOKE_OK bytes=268435456 baseline_kb=8616 max_kb=8896 delta_kb=280
GATEWAY_AUTHZ_SMOKE_OK node_a=node-a node_b=node-b missing_jwt=403 backend_requests=2
WEBDAV_GATEWAY_STREAM_SMOKE_OK bytes=67108864 baseline_kb=8672 max_kb=14472 delta_kb=5800
WEBDAV_GATEWAY_STREAM_SMOKE_OK bytes=10737418240 baseline_kb=10648 max_kb=14864 delta_kb=4216
STACK_SMOKE_OK nodes=4 running=4 ready=4 image=alpine:3.20.0
CLUSTER_PREFLIGHT_PLAN path=/tmp/cs-cluster-preflight-collector/install-plan.sh missing_tsv=/tmp/cs-cluster-preflight-collector/missing.tsv packages_tsv=/tmp/cs-cluster-preflight-collector/packages.tsv manual_tsv=/tmp/cs-cluster-preflight-collector/manual.tsv logged_nodes_tsv=/tmp/cs-cluster-preflight-collector/logged-nodes.tsv collected_logs=/tmp/cs-cluster-preflight-collector/collected-logs.txt verify=/tmp/cs-cluster-preflight-collector/verify-after-install.sh
CLUSTER_PREFLIGHT_OK logged_nodes=4 nodes=4 ready=4 image=alpine:3.20
ACCEPTANCE_AUDIT_COMPLETE total=17 pass=17 out=/tmp/cs-storage-acceptance-audit.tsv
PRODUCTION_SECRETS_PREFLIGHT_OK warnings=0 logged_nodes=3 completed=4 ready=4 env_dir=/etc/cs-storage
PRODUCTION_READINESS_GATE_OK out=/tmp/cs-storage-production-readiness
PRODUCTION_PATH_PREPARE_OK nodes=4 ready=4 image=alpine:3.20 volume_root=/mnt/cs_storage/vols log_root=/var/log/cs-storage
PRODUCTION_PATH_PREFLIGHT_OK nodes=4 ready=4 image=alpine:3.20 issues_tsv=/tmp/cs-storage-production-path-preflight/issues.tsv
PRODUCTION_PATH_GLOBAL_SMOKE_OK nodes=4 ready=4 image=cs-storage:hd01-smoke tester=docker:27-cli driver=cs-storage-prodpath-smoke root=/mnt/cs_storage/vols/.cs-prodpath-smoke
PRODUCTION_DRIVER_SMOKE_OK nodes=4 ready=4 image=cs-storage:hd01-smoke tester=docker:27-cli driver=cs-storage root=/mnt/cs_storage/vols/.cs-production-driver-smoke
SWARM_FUSE_DEVICE_SMOKE_ISSUES ok=0 issues=4 nodes=4 ready=4 image=alpine:3.20
HOST_DAEMON_WEBDAV_WORKLOAD_SMOKE_OK node=hd01 driver=cs-storage-host-webdav-smoke volume=cs-host-webdav-smoke-vol remote_root=cs-storage-host-webdav-smoke-1779410046-4142920
PRIV_DAEMON_WEBDAV_GLOBAL_SMOKE_OK nodes=4 verified=4 ready=4 image=cs-storage:hd01-smoke driver=cs-storage-priv-webdav-smoke remote_root=cs-storage-priv-webdav-smoke-1779415094-287919
SHARED_MULTI_SYNC_WEBDAV_SMOKE_OK node=hd01 driver=cs-storage-shared-sync-webdav-smoke volume=cs-shared-sync-webdav-smoke-vol remote_root=cs-storage-shared-sync-webdav-smoke-1779441082-1985452 file=periodic-sync.txt
SHARED_MULTI_DB_SYNC_WEBDAV_SMOKE_OK node=hd01 driver=cs-storage-shared-db-sync-webdav-smoke volume=cs-shared-db-sync-webdav-smoke-vol remote_root=cs-storage-shared-db-sync-webdav-smoke-1779473948-4149239 db=main.db integrity=ok rows=1
DAEMON_MANAGED_VOLUME_SMOKE_OK volume=cs-managed-volume-smoke-vol-3372470 driver=cs-storage-managed-volume-smoke-3372470 mountpoint=/mnt/cs_storage/vols/.cs-managed-volume-smoke-3372470/cs-managed-volume-smoke-vol-3372470/mount elapsed=1s rows=2
CLUSTER_PREFLIGHT_OK logged_nodes=4 nodes=4 ready=4 image=alpine:3.20
PRODUCTION_SECRETS_PREFLIGHT_OK warnings=0 logged_nodes=3 completed=4 ready=4 env_dir=/etc/cs-storage
PRODUCTION_STACK_PLAN_OK nodes=4 image=cs-storage:formal-20260524-sandbox dummy=0 out=/tmp/cs-storage-production-stack-plan
IMAGE_LOAD_SMOKE_OK nodes=4 ready=4 image=cs-storage:formal-20260524-sandbox loader=docker:27-cli server=busybox:1.36
FORMAL_PRODUCTION_DEPLOY_OK image=cs-storage:formal-20260524-sandbox service=cs-storage-server_gateway healthz=204 nodes=4
FORMAL_DRIVER_NODE_OK node=hd01 volume=cs-formal-verify-hd01-fixed2 file=formal-global-hd01-fixed2.txt
FORMAL_DRIVER_NODE_OK node=ora01 volume=cs-formal-verify-ora01-fixed2 file=formal-global-ora01-fixed2.txt
FORMAL_DRIVER_NODE_OK node=ora02 volume=cs-formal-verify-ora02-fixed2 file=formal-global-ora02-fixed2.txt
FORMAL_DRIVER_NODE_OK node=wawo01 volume=cs-formal-verify-wawo01-fixed2 file=formal-global-wawo01-fixed2.txt
FORMAL_WEBDAV_REMOTE_GET_OK nodes=4 files=hd01,ora01,ora02,wawo01 status=200 backend=https://rausu.infini-cloud.net/dav/nodes/
DEB_BUILD_OK path=dist/cs-storage_0.1.1_amd64.deb sha256=ccc07a9ec38a972349cec3d4b4b1a8b9d94ffce19146022e5bb4168a2b49da5e source=GitHub-Actions
CSS_REPEAT_INSTALL_SECRET_STABLE_OK node_secret_sha256=cb6499904cdca831ab0479ddc929bff78c9cb5756055264d411968de39fe42fa gocryptfs_password_sha256=13a012b2f816ce07909495c1c6236cd82cde411548a1a35fd0a39f918e87cd47
CSS_SYSTEMD_NODE_INSTALL_OK role=all node=hd01 driver=css env_dir=/etc/cs-storage prefix=/usr/local/bin
SYSTEMD_SERVICES_ACTIVE enabled=3 active=3 services=cs-storage-server,cs-storage-daemon,cs-storage-plugin
SYSTEMD_SERVER_HEALTHZ http_status=204
SYSTEMD_OFFICIAL_SOCKETS_OK daemon=/run/cs-storage.sock plugin=/run/docker/plugins/css.sock
CSS_FORMAL_DRIVER_NODE_OK node=hd01 volume=css-release-final-hd01 driver=css mountpoint=/mnt/cs_storage/vols/css-release-final-hd01/mount package=GitHub-Release
CSS_WEBDAV_REMOTE_GET_OK node=hd01 file=css-release-final-hd01.txt status=200 content=css-release-final-hd01 backend=https://rausu.infini-cloud.net/dav/nodes/hd01/
SYSTEMD_CONFIG_PERMS_OK env=0640 root:cs-storage secrets_dir=0750 root:cs-storage
DISPOSABLE_LAB_ONLY_ACCEPTED: destructive partition/split-brain tests must not be run on the live hd01 cluster; disposable lab coverage remains a separate safety exercise.
```

The gateway authz smoke used a Node-A JWT to upload to a client-supplied Node-B path and verified the backend still received the object under Node-A sandbox, the backend Authorization header was replaced with the configured Basic credential, and a missing-JWT upload returned 403 before reaching the backend. The gateway stream smoke test uploaded a 256 MiB sparse payload through `cs-storage-server` into a local sink backend and sampled server RSS. The backend received the full byte count while RSS grew by 280 KiB, verifying the reverse proxy path streams request bodies instead of buffering them in memory. The real WebDAV smoke uploaded both 64 MiB and 10 GiB sparse payloads through the same gateway path into the configured WebDAV backend, verified remote `getcontentlength`, and cleaned the temporary remote collection afterward; the 10 GiB run satisfies the v6.0 real-backend streaming acceptance threshold with a 4.2 MiB RSS increase.

The currently packaged formal target runs `cs-storage-server.service`, `cs-storage-daemon.service`, and `cs-storage-plugin.service` as host services. The installer accepts file-backed backend and node secrets under `/etc/cs-storage/secrets`, keeps values out of tracked files, and starts the official `cs-storage` Docker VolumeDriver socket. Earlier `MKCOL` 301 and missing parent collection failures were fixed in the gateway by preparing and confirming backend sandbox collections during node auth. Destructive partition, node-drain, and split-brain tests remain explicitly excluded from the live hd01 cluster and require a disposable lab.

The daemon-managed volume smoke starts `cs-storage-daemon` with `CS_MANAGED_VOLUMES`, waits for the daemon itself to create and maintain a LiteFS-backed mount before the Docker plugin starts, then mounts the same volume through Docker and verifies the driver reuses the already-maintained mountpoint instead of owning the storage setup. The smoke also verifies that the managed declaration contains no `flush`, and Docker mount resolves runtime options from daemon-owned managed config rather than persisted volume metadata.

The chattr guard smoke test started the daemon with `CS_ENABLE_CHATTR=true`, created a volume, and verified a direct directory creation under the guarded root failed after the daemon re-locked the root.

The Docker plugin smoke test exercised Docker -> VolumeDriver socket -> plugin -> daemon create/inspect/remove. It also started a separate `cs-storage-failfast` plugin socket with a missing daemon socket and verified both `docker volume create` and `docker run -v` returned `daemon unavailable` without creating an isolated bare root directory (`DOCKER_PLUGIN_FAILFAST_SMOKE_OK elapsed=5s`).

The Consul coordinator smoke test exercised JWT-protected Consul-style KV JSON reads, raw reads, session creation, KV lock acquisition failure/success semantics, and session TTL lock release.

The Kopia backup smoke created a real filesystem Kopia repository with an explicit config file, started the daemon with `CS_KOPIA_CONFIG_PATH`, `CS_KOPIA_SNAPSHOT_INTERVAL=1s`, and `CS_KOPIA_POLICY_ARGS`, created a `cs.backup=auto` volume, wrote a payload to its mountpoint, verified a periodic snapshot and policy update appeared before remove, removed the volume to trigger the final snapshot hook, restored the latest snapshot, and verified the restored payload matched the source.

The restore admin smoke test used a fake rclone backend to list two timestamped backups, selected the lexicographically latest backup with `restore -source-root ... -latest -volume ...`, renamed the existing target to `.BAK.<timestamp>`, and restored the selected backup into a fresh mount directory.

The deploy artifacts smoke test checked installer shell syntax, Stack environment-variable parity (`STACK_ENV_PARITY_OK`), staged installer output (`INSTALL_ARTIFACTS_STAGED_OK`), systemd unit structure, Compose parsing for the gateway/daemon/plugin Stack templates, and example app volume label rendering. The daemon Stack smoke rendered `deploy/stack/cs-storage-daemon-global.yml` through both `docker compose config` and `docker stack config`, verifying the global mode, node hostname templating, declared `/dev/fuse` device, `SYS_ADMIN`, and `rshared` mount propagation fields without starting the live daemon service; the focused FUSE device smoke shows hd01 Docker Stack still ignores `devices` at deploy time. The Swarm image-load smoke distributed the hd01-built `cs-storage:hd01-smoke` image to all 4 Ready nodes through a temporary overlay-network `busybox httpd` service and `docker:27-cli` global loader service. The daemon global run smoke then started a temporary global daemon service on all 4 Ready nodes with an in-container `/tmp` socket/root, `CS_ENABLE_CHATTR=false`, and no FUSE mounts, verifying each daemon reached socket-ready state before removing the Stack. The plugin+daemon global smoke started temporary daemon, plugin, and tester services on all 4 Ready nodes using the isolated `cs-storage-swarm-smoke` VolumeDriver socket; each tester used its node-local Docker socket to create, inspect, and remove a `cs.crypt=false` volume through the same-node plugin/daemon path before the Stack was removed. The runtime image smoke built `cs-storage:hd01-smoke` and verified the final image contains all CS-Storage binaries plus LiteFS v0.5.14, Kopia 0.23.0, rclone, gocryptfs, GlusterFS client/server, sqlite3, and FUSE userspace tools. The server Stack smoke deployed `deploy/stack/cs-storage-server.yml` as a temporary Swarm Stack using the hd01-built image, verified `/healthz` on port 18080, and removed the Stack afterward.

The LiteFS daemon global smoke used a Swarm global launcher plus each node local Docker socket to start temporary privileged daemon/plugin containers, created a `cs.mode=shared`, `cs.write=multi`, `cs.engine=sqlite` volume on each Ready node with `flush=true`, wrote 20 SQLite rows through the Docker VolumeDriver and real LiteFS FUSE mount, verified `PRAGMA integrity_check` returned `ok`, and removed the temporary Stack and sockets.

The LiteFS Consul smoke started `cs-storage-server` as the Consul-compatible coordinator with `CS_COORDINATOR_TOKEN`, launched two real LiteFS nodes, wrote a SQLite row on the primary, verified the replica saw the row, and checked `PRAGMA integrity_check`. The global LiteFS Consul smoke then distributed the hd01-built image to all 4 Ready nodes, started one LiteFS node per Swarm node through a global launcher, elected hd01 as primary via the coordinator, wrote one SQLite row, and verified all four nodes read the row with `integrity=ok`. The remote-write smoke uses the same coordinator path and Swarm global launcher pattern, has each of the 4 Ready nodes write 8 rows to the same SQLite database through its local LiteFS node using `litefs run -promote`, and verifies every node sees 33 total rows including the initialization row with `PRAGMA integrity_check=ok`. `scripts/hd01-litefs-consul-stress-smoke.sh` is a non-disruptive stress variant that reuses the same launcher path with isolated names, ports, and root paths; the verified modes perform 512-row and 2048-row primary bulk writes and check every Ready node reaches the expected row count with `PRAGMA integrity_check=ok`.

The Gluster daemon global smoke used the same Swarm global launcher pattern to start temporary node-local Gluster server, daemon, and plugin containers on all 4 Ready nodes. It created a `cs.mode=shared`, `cs.write=multi`, `cs.engine=static` Docker volume, wrote `static.txt` through the VolumeDriver into a real Gluster FUSE mount, read the file back, verified the daemon-managed Gluster log path, and removed the temporary Stack, config, sockets, and volumes.

The Gluster replica smoke used temporary node-local glusterd containers, created a real `replica 3 arbiter 1` volume across three Ready nodes, mounted that same volume from all 4 Ready nodes, wrote one `node=<name>` file from each client, waited until each client saw all four files, and cleaned the temporary Stacks, Docker configs, containers, and hidden smoke root. This validates non-disruptive cross-node Gluster consistency; split-brain and partition behavior remains intentionally untested on live hd01.

The router smoke test mounted the Go-FUSE router, wrote a normal config file to the Gluster backing directory, wrote a SQLite database file to the LiteFS backing directory, and confirmed another file in the SQLite parent directory stayed pinned to LiteFS. Router unit coverage also verifies Setattr chmod/truncate/mtime passthrough, symlink/readlink, same-engine hardlink creation, and cross-engine hardlink rejection with `EXDEV`. The router SQLite smoke used the hd01-built image sqlite3 binary through Docker bind mounts, enabled WAL mode, ran both 4 concurrent writers for 400 total rows and 8 concurrent writers for 4000 total rows, verified `PRAGMA integrity_check` returned `ok`, and confirmed post-database files in the same directory stayed pinned to LiteFS.
