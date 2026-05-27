# CS-Storage Production Rollout Runbook

This runbook is derived from `技术方案.v0.txt`, `技术方案.v1.txt`, and the current hd01 evidence in `README.md`. It is intentionally command-oriented so the remaining production acceptance work can be resumed without re-reading the whole chat history.

## Hard Safety Rules

- Do not compile or test locally. Build, test, deploy, and Swarm validation happen on hd01.
- Do not run live destructive network tests on hd01: no node drain/offline, firewall/route changes, `tc/netem`, Docker network disconnect, split-brain induction, or forced network partitions.
- Do not write WebDAV, SSH, JWT, Kopia, gocryptfs, or backend credentials into git-tracked files.
- Host dependency rollout changes all Ready Swarm nodes. It requires explicit operator approval before running `APPLY=1 ACK_INSTALL_HOST_DEPS=yes`.

## Connection Note

The `hd01` SSH alias may use a local SOCKS `ProxyCommand`. If `ssh hd01` stalls during banner exchange but the direct endpoint is reachable, use the direct form:

```sh
ssh -o ProxyCommand=none -o IdentitiesOnly=yes   -i <identity-file-for-hd01>   -p 16022 root@108.62.161.204
```

If `nc -vz 108.62.161.204 16022` succeeds but SSH still fails, run one short diagnostic:

```sh
HD01_IDENTITY=<identity-file-for-hd01> ./scripts/hd01-ssh-diagnose.sh
```

Observed failure modes on 2026-05-23 included timeout while waiting for `SSH2_MSG_KEX_ECDH_REPLY`, even after forcing `KexAlgorithms=curve25519-sha256`, and later a pre-banner `Not allowed at this time` response followed by connection close/reset. Treat either as sshd/connection-pressure state and do not start long-running remote work. Wait for sshd to recover.

## Current Acceptance Summary

Run the read-only audit:

```sh
./scripts/hd01-acceptance-audit.sh
```

Current known result:

```text
ACCEPTANCE_AUDIT_COMPLETE total=17 pass=17
```

Run the aggregate non-destructive production gate from hd01 when you need one blocking readiness answer:

```sh
./scripts/hd01-production-readiness-gate.sh
```

The gate runs the acceptance audit, production path preflight, cluster dependency preflight, production secrets/backend preflight, and dummy plus real production Stack plan rendering. It writes per-check logs under `/tmp/cs-storage-production-readiness`. Current expected result after formal deployment is:

```text
PRODUCTION_READINESS_GATE_OK
```

The live hd01 production blockers are closed for the requested delivery scope. Destructive Gluster/LiteFS partition, node-drain, and split-brain tests remain excluded from the live cluster and require a disposable lab.

## Production Install Entrypoint

The formal production install path is host systemd, not CS-Storage runtime containers. Use the role-specific wrappers for normal installs; they download the release `.deb`, write only the needed config, and refuse accidental secret replacement.

The installers set apt/deb work to non-interactive mode, including
`needrestart` after library upgrades. If an older run is already stuck in a
package configuration screen, interrupt that run and rerun the current
one-command installer from GitHub.

For rollback, `sudo apt-get remove -y cs-storage` removes package-managed
binaries and units while keeping node data. `sudo apt-get purge -y cs-storage`
is the full cleanup path and removes CSS config/secrets, state, logs,
`/mnt/cs_storage`, sockets, and the `cs-storage` system user/group. Removal is
blocked with a clear `CSS_PURGE_BLOCKED` message if `css` Docker volumes,
containers using those volumes, or active CSS mounts still exist. Stop/remove
the stacks and volumes first; use `sudo env CSS_STORAGE_PURGE_FORCE=1 apt-get
purge -y cs-storage` only for emergency cleanup.

The package also enables `cs-storage-auto-upgrade.timer`. It checks GitHub
latest Release and installs a newer deb while preserving `/etc/cs-storage`
configuration and secrets. The active-development interval is `5s`; final
long-term delivery should use `1min`.

Server only:

```sh
curl -fsSL https://raw.githubusercontent.com/Loongel/cloud-shared-storage/main/scripts/css-install-server.sh \
  | sudo sh -s -- \
  --backend-url <webdav-or-s3-http-url> \
  --backend-user '<backend-user>' \
  --backend-password '<backend-password>'
```

The server/all wrapper binds the service to NetBird `wt0` by default, writes
`CS_PUBLIC_URL` using the NetBird FQDN when available, and prints a filled
`CSS_CLIENT_INSTALL_COMMAND` for client nodes after installation. The command
contains `--node-secret '<value>'`, so client nodes do not need a separate
secret file copy. The same command is saved on the server as
`/etc/cs-storage/client-install-command.sh` with mode `0700`.

Client only:

```sh
curl -fsSL https://raw.githubusercontent.com/Loongel/cloud-shared-storage/main/scripts/css-install-client.sh \
  | sudo sh -s -- \
  --server-url http://<server-netbird-fqdn-or-wt0-ip>:<server-port> \
  --node-secret '<node-secret-from-server-output>'
```

Server plus client on the same node:

```sh
curl -fsSL https://raw.githubusercontent.com/Loongel/cloud-shared-storage/main/scripts/css-install-all.sh \
  | sudo sh -s -- \
  --backend-url <webdav-or-s3-http-url> \
  --backend-user '<backend-user>' \
  --backend-password '<backend-password>'
```

The package also includes the lower-level `cs-storage-systemd-node-install` for advanced automation. It is more explicit and expects file-backed secrets:

```sh
ACK_INSTALL_HOST_DEPS=yes \
curl -fsSL https://raw.githubusercontent.com/Loongel/cloud-shared-storage/main/scripts/cs-storage-systemd-node-install.sh -o /tmp/cs-storage-install.sh
sh /tmp/cs-storage-install.sh \
  --deb-url https://github.com/Loongel/cloud-shared-storage/releases/download/v0.1.20/cs-storage_0.1.20_amd64.deb \
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

Use `--role server` or `--role client` for split server/client deployments. Set `--backend-auth-header-file` instead of the backend user/password pair when that is the backend auth model. The historical `scripts/hd01-production-install.sh` and Swarm launcher smokes remain as validation and migration aids, but they are not the formal production runtime.

Secret rules:

- `node_secret` must be identical on server and clients. Server/all generates it only on first install if absent; client-only requires it.
- `gocryptfs_password` is generated only on first server/all/client install if absent. It must be identical on clients that need to read the same encrypted shared volume. Server/all prints it in the client bootstrap command by default. Back it up before using encrypted volumes.
- Repeat installs reuse existing secret files. Different replacement values are refused unless `--force-secret-update` is passed, and the old file is backed up first.
- Server/all installer output prints a client bootstrap command containing `node_secret` and `gocryptfs_password` by default. Treat that command and `/etc/cs-storage/client-install-command.sh` as secrets; pass `--no-print-client-secret` to suppress it.
- Node id defaults to the NetBird FQDN from `netbird status`, then host name. Pass `--node-id` only when you need a fixed custom identity.
- Use `--bind-interface <iface>`, `--server-addr <addr:port>`, or `--public-url <url>` only when the default `wt0` address and NetBird FQDN are not correct for the client network.


## Non-Destructive Validation Order

From `/tmp/cs-storage-work-current` on hd01:

For scripts that build helper binaries from source, either keep `/tmp/cs-storage-work-current` refreshed to the current source or pass `WORKDIR=/tmp/cs-storage-work-<timestamp>` explicitly. The smoke scripts now default to `/tmp/cs-storage-work-current` instead of the older `/tmp/cs-storage-work` path.

```sh
sh -n scripts/hd01-cluster-preflight.sh   scripts/hd01-cluster-deps-rollout.sh   scripts/hd01-production-secrets-preflight.sh   scripts/hd01-acceptance-audit.sh
```

```sh
SMOKE=/tmp/cs-cluster-preflight-collector ./scripts/hd01-cluster-preflight.sh
```

Expected current state after dependency rollout:

```text
CLUSTER_PREFLIGHT_OK logged_nodes=4 nodes=4 ready=4 image=alpine:3.20
```

The guarded host dependency rollout remains dry-run by default for future reinstalls:

```sh
PREFLIGHT_SMOKE=/tmp/cs-cluster-preflight-collector ./scripts/hd01-cluster-deps-rollout.sh
```

Expected safe dry-run:

```text
CLUSTER_DEPS_ROLLOUT_DRY_RUN image=cs-storage:hd01-smoke ready=4 min=4
```

If `docker build` fails inside the build container with `Temporary failure resolving 'deb.debian.org'`, rebuild on hd01 with `docker build --network host -t cs-storage:hd01-smoke .`; this uses host networking only for the build container and does not change host network configuration.
When Docker service logs are partial on hd01, the Swarm smoke scripts also check task state. `IMAGE_LOAD_LOGS_PARTIAL`, `DAEMON_GLOBAL_LOGS_PARTIAL`, and `PLUGIN_DAEMON_GLOBAL_LOGS_PARTIAL` are acceptable only when all required tasks are Running or Complete and the script still emits the corresponding `*_SMOKE_OK` token.

Verify the apply gate refuses missing acknowledgement:

```sh
APPLY=1 ./scripts/hd01-cluster-deps-rollout.sh
```

Expected refusal:

```text
CLUSTER_DEPS_REFUSE_APPLY missing_ack=ACK_INSTALL_HOST_DEPS=yes
```

Run the read-only production secrets/backend preflight after SSH and Docker are stable:

```sh
./scripts/hd01-production-secrets-preflight.sh
```

This checks `/etc/cs-storage/server.env`, `daemon.env`, `plugin.env`, and any referenced `KEY_FILE` entries on every Ready node without printing secret values. The paired bootstrap helper is guarded and dry-run by default:

```sh
CS_NODE_SECRET_KEY=<secret> \
CS_BACKEND_URL=<webdav-or-s3-http-url> \
CS_BACKEND_USER=<backend-user> \
CS_BACKEND_PASSWORD=<backend-password> \
CS_SERVER_URL=<production-server-url> \
CS_GOCRYPTFS_PASSWORD=<gocryptfs-passphrase> \
./scripts/hd01-production-secrets-bootstrap.sh
```

Expected dry-run token:

```text
PRODUCTION_SECRETS_BOOTSTRAP_DRY_RUN
```

Apply mode without `ACK_WRITE_PRODUCTION_SECRETS=yes` must refuse with `PRODUCTION_SECRETS_BOOTSTRAP_REFUSE_APPLY missing_ack=ACK_WRITE_PRODUCTION_SECRETS=yes`; this refusal was verified on hd01 and does not write `/etc/cs-storage`. In apply mode, the helper writes env files that reference file-backed secrets under `/run/cs-storage-secrets/*` and writes the host-side secret files under `/etc/cs-storage/secrets/*` with mode `0600`. The non-production smoke `scripts/hd01-production-secrets-bootstrap-smoke.sh` runs the same apply path against temporary `/tmp/cs-storage-production-secrets-bootstrap-smoke-env-*` directories across all Ready nodes, verifies strict preflight and `KEY_FILE_OK`, then removes the temporary tree; hd01 verified `PRODUCTION_SECRETS_BOOTSTRAP_FILE_SECRET_SMOKE_OK`.

## Host Dependency Rollout

Only after explicit operator approval:

```sh
APPLY=1 ACK_INSTALL_HOST_DEPS=yes   PREFLIGHT_SMOKE=/tmp/cs-cluster-preflight-collector   ./scripts/hd01-cluster-deps-rollout.sh
```

It installs apt-managed host tools on every Ready node:

```text
glusterfs-client sqlite3 rclone gocryptfs fuse3
```

It copies runtime binaries from `cs-storage:hd01-smoke` to `/usr/local/bin` on each node:

```text
litefs kopia
```

After rollout, re-run:

```sh
SMOKE=/tmp/cs-cluster-preflight-after-deps STRICT=1 ./scripts/hd01-cluster-preflight.sh
```

Acceptance requires no missing tools and all Ready nodes logged.

## Production Secrets/Backend Bootstrap

Create real env files outside git on every node or through a secure operator flow. Do not commit values.
Use file mode `0600` for writable root-owned env files, or `0400` for read-only root-owned env files; the production preflight marks group/world-readable or writable modes as insecure.
`server.env` and `daemon.env` must use the same node secret, either directly through `CS_NODE_SECRET_KEY` or preferably through `CS_NODE_SECRET_KEY_FILE`. Backend auth must be present through either `CS_BACKEND_AUTH_HEADER(_FILE)` or both `CS_BACKEND_USER(_FILE)` and `CS_BACKEND_PASSWORD(_FILE)`. The preflight reports mismatches without printing secret values. To create the three env files plus `/etc/cs-storage/secrets/*` on every Ready Swarm node through a temporary global helper, pass the same variables shown above and explicitly acknowledge the write:

```sh
APPLY=1 ACK_WRITE_PRODUCTION_SECRETS=yes \
CS_NODE_SECRET_KEY=<secret> \
CS_BACKEND_URL=<webdav-or-s3-http-url> \
CS_BACKEND_USER=<backend-user> \
CS_BACKEND_PASSWORD=<backend-password> \
CS_SERVER_URL=<production-server-url> \
CS_GOCRYPTFS_PASSWORD=<gocryptfs-passphrase> \
./scripts/hd01-production-secrets-bootstrap.sh
```

The helper uses temporary Docker secrets and removes them after the global job completes. It writes `CS_NODE_ID=<node hostname>` into each node daemon env file. The generated Stack templates bind-mount `/etc/cs-storage/secrets` to `/run/cs-storage-secrets:ro`, so sensitive values can stay out of the Swarm service environment.

Required `server.env` keys:

```text
CS_NODE_SECRET_KEY or CS_NODE_SECRET_KEY_FILE
CS_BACKEND_URL
CS_BACKEND_AUTH_HEADER(_FILE) or CS_BACKEND_USER(_FILE) + CS_BACKEND_PASSWORD(_FILE)
```

Required `daemon.env` keys:

```text
CS_SERVER_URL
CS_NODE_ID
CS_NODE_SECRET_KEY or CS_NODE_SECRET_KEY_FILE
CS_GOCRYPTFS_PASSWORD or CS_GOCRYPTFS_PASSWORD_FILE
```

Required `plugin.env` keys:

```text
CS_PLUGIN_SOCKET
CS_DAEMON_SOCKET
CS_DOCKER_SOCKET
```

Then render the production Stack plan without deploying it:

```sh
./scripts/hd01-production-stack-plan.sh
```

For template-only validation before real env files exist:

```sh
DUMMY=1 ./scripts/hd01-production-stack-plan.sh
```

Expected non-deploy tokens are `PRODUCTION_STACK_PLAN_REDACTED_OK` and `PRODUCTION_STACK_PLAN_OK`. If real env files are still absent, the script stops with `PRODUCTION_STACK_PLAN_MISSING_ENV` and does not deploy anything.

Then run:

```sh
STRICT=1 ./scripts/hd01-production-secrets-preflight.sh
```

## Final Non-Destructive Production Checks

After dependency rollout and secret/backend preflight pass:

```sh
./scripts/hd01-production-path-preflight.sh
./scripts/hd01-production-driver-smoke.sh
./scripts/hd01-privileged-daemon-webdav-global-smoke.sh
./scripts/hd01-shared-multi-db-sync-webdav-smoke.sh
./scripts/hd01-webdav-env-run.sh ./scripts/hd01-privileged-shared-multi-db-sync-webdav-global-smoke.sh < /tmp/cs-storage-webdav.env

./scripts/hd01-acceptance-audit.sh
```

Credentials for WebDAV smokes should be supplied through `scripts/hd01-webdav-env-run.sh` or a pre-created 0400/0600 env file under `/tmp`, `/run/secrets`, or `/etc/cs-storage`; do not put WebDAV values in command lines, git files, or Stack YAML. From the operator machine, `scripts/hd01-webdav-smoke-ssh.sh` can pipe the env over SSH stdin to hd01 without placing values in the SSH command line. The wrapper refusal path is verified with `WEBDAV_ENV_RUN_REFUSE_OK` for incomplete input.

Do not run the destructive failure-mode tests on live hd01. Move those to a disposable lab and record separate evidence.
