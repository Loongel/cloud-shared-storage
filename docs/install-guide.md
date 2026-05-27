# CSS Install Guide

Cloud Shared Storage (CSS) installs as host systemd services. The Docker volume
driver name is `css`.

Use the role-specific wrappers for normal installs:

- `css-install-server.sh`: server gateway only.
- `css-install-client.sh`: client daemon plus Docker VolumeDriver plugin only.
- `css-install-all.sh`: server plus client on the same node.

`css-install-server.sh` is intentionally server-only. It enables and starts
`cs-storage-server.service` only; it does not create `daemon.env` or
`plugin.env`, so `cs-storage-daemon.service` and `cs-storage-plugin.service`
remain disabled/inactive unless client config already exists from an earlier
client/all install. Use `css-install-all.sh` on a gateway node that should also
provide the local Docker volume driver.

The lower-level `cs-storage-systemd-node-install.sh` is for advanced automation
and package tests.

## Required Inputs

Server-only fresh install requires only backend storage details:

```sh
curl -fsSL https://raw.githubusercontent.com/Loongel/cloud-shared-storage/main/scripts/css-install-server.sh \
  | sudo sh -s -- \
  --backend-url https://example.invalid/dav/ \
  --backend-user '<webdav-user>' \
  --backend-password '<webdav-password>'
```

The installer stores those inline values in root-owned files under
`/etc/cs-storage/secrets/`. Use `--backend-user-file` and
`--backend-password-file` when you already manage secrets as files. Use
`--backend-auth-header` or `--backend-auth-header-file` instead of user/password
when the backend requires a complete Authorization header.

By default, server/all installs bind `cs-storage-server.service` to the IPv4
address on NetBird interface `wt0`. The public URL printed and written for
clients uses the NetBird FQDN from `netbird status` when available, then falls
back to the `wt0` IP or host name. Override with `--bind-interface`,
`--server-addr`, or `--public-url` only when your topology requires it.

At the end of a server/all install, the script prints `CSS_CLIENT_INSTALL_COMMAND`,
a readable multi-line client command using the selected public server URL. The command
contains `--node-secret '<value>'`, so the client writes its own
`/etc/cs-storage/secrets/node_secret` during install and no separate file-copy
step is needed. The same command is saved on the server as
`/etc/cs-storage/client-install-command.sh` with mode `0700`.

Client-only fresh install requires the server URL and the exact `node_secret`
from the server:

```sh
curl -fsSL https://raw.githubusercontent.com/Loongel/cloud-shared-storage/main/scripts/css-install-client.sh \
  | sudo sh -s -- \
  --server-url http://<server-netbird-fqdn-or-wt0-ip>:<server-port> \
  --node-secret '<node-secret-from-server-output>'
```

`node_secret` is the shared server/client authentication secret, not the node's
identity. The node id defaults to the NetBird FQDN from `netbird status`, then
falls back to the host name, unless you pass `--node-id`. Use the client command
printed by the server installer, or pass the value with `--node-secret
'<value>'`. Use `--node-secret-file` only when your own automation already
manages that secret as a file.

Server plus client on the same node requires backend storage details only. The
local client URL is inferred from the same NetBird-facing server URL. This is
the command to use when the server node itself should run all three systemd
services: `cs-storage-server`, `cs-storage-daemon`, and `cs-storage-plugin`.

```sh
curl -fsSL https://raw.githubusercontent.com/Loongel/cloud-shared-storage/main/scripts/css-install-all.sh \
  | sudo sh -s -- \
  --backend-url https://example.invalid/dav/ \
  --backend-user '<webdav-user>' \
  --backend-password '<webdav-password>'
```

## Defaults

- Driver name: `css`.
- Node id: NetBird FQDN from `netbird status`, then host name.
- Server bind: NetBird `wt0` IPv4 address when available.
- Server port: first free port in `18080-18100`.
- Public URL: NetBird FQDN when available, then `wt0` IP or host name.
- Host dependencies: installed by default; pass `--no-install-deps` to skip.
- Services: enabled and started by default.
- Release package: latest configured script release URL.
- Release `.deb` packages are built with `xz` compression for compatibility
  with older `dpkg` versions that do not support `control.tar.zst`.
- Apt/deb installation is forced non-interactive, including `needrestart`
  prompts after library upgrades.
- Final install output is separated into highlighted summary blocks. Set
  `CSS_OUTPUT_COLOR=never` to disable ANSI color.
- Client/all installs also write usable shared-multi defaults:
  `CS_GLUSTER_REMOTE`, `CS_LITEFS_ADVERTISE_URL`, and
  `CS_RCLONE_SYNC_INTERVAL=30s`.
- Realtime rclone mounts default `CS_RCLONE_DIR_CACHE_TIME=2s` so
  shared-single reader nodes refresh the single writer's directory updates
  promptly. Increase it only when you accept slower cross-node visibility.
- Server/all installs create and start a default host GlusterFS volume named
  `css_shared` when GlusterFS is available.
- Client/all installs create a local encrypted Kopia filesystem repository for
  `cs.backup=true`, with config at `/etc/cs-storage/kopia.repository.config`
  and password at `/etc/cs-storage/secrets/kopia_password`.

If an existing `/etc/cs-storage/server.env` or `daemon.env` is present, repeat
installs reuse values from those files instead of choosing new values.

## Secret Lifecycle

`node_secret` authenticates clients to the server.

- Server/all generates it only on first install when absent.
- Client-only never generates it.
- Every client must use the same `node_secret` as the server.
- Server/all prints a one-command client installer with `node_secret` inline by
  default, and saves it as `/etc/cs-storage/client-install-command.sh`.
- Back up `/etc/cs-storage/secrets/node_secret` immediately after first server
  install.

`gocryptfs_password` decrypts encrypted volumes.

- Client/all generates it only on first install when absent.
- Existing file is reused on repeat install.
- Changing it after encrypted volumes exist makes old encrypted data unreadable.
- Back up `/etc/cs-storage/secrets/gocryptfs_password` before using encrypted
  volumes.

`kopia_password` decrypts local backup snapshots created by `cs.backup=true`.

- Client/all generates it only on first install when absent.
- Existing file and repository config are reused on repeat install.
- Back up `/etc/cs-storage/secrets/kopia_password` together with
  `/etc/cs-storage/kopia.repository.config`.

Backend credentials are never generated. Fresh server/all install requires either:

- `--backend-auth-header-file`, or
- `--backend-user-file` plus `--backend-password-file`, or their inline value
  equivalents.

Server/all prints the client bootstrap command with `node_secret` inline by
default. Treat that command as a secret. Pass `--no-print-client-secret` if you
want the older file-copy style output instead. The installer also prints SHA256
fingerprints so operators can verify that nodes are using matching secret files.

## Reinstall And Rotation

Repeat installs reuse existing files under `/etc/cs-storage/secrets`.

If you pass a different value for an existing secret, the install refuses by
default. For intentional rotation:

```sh
curl -fsSL https://raw.githubusercontent.com/Loongel/cloud-shared-storage/main/scripts/css-install-server.sh \
  | sudo sh -s -- \
  --backend-url https://example.invalid/dav/ \
  --backend-user '<webdav-user>' \
  --backend-password '<webdav-password>' \
  --force-secret-update
```

The old file is copied to `*.BAK.<timestamp>` before replacement. Do not rotate
`gocryptfs_password` for existing encrypted volumes unless you have a migration
plan.

## Uninstall

Use `remove` when you only want to remove package-managed binaries and units
while keeping node data:

```sh
sudo apt-get remove -y cs-storage
```

Use `purge` for a full node cleanup. This removes package files, CSS config,
secrets, state, logs, `/mnt/cs_storage`, sockets, and the `cs-storage` system
user/group. The deb maintainer script refuses removal if Docker still has
`css` volumes, containers using those volumes, or active mounts under
`/mnt/cs_storage/vols`; stop the owning stacks/containers and remove those
volumes first:

```sh
sudo apt-get purge -y cs-storage
```

Emergency forced cleanup is available, but should only be used after confirming
no application still needs the mounted data:

```sh
sudo env CSS_STORAGE_PURGE_FORCE=1 apt-get purge -y cs-storage
```

The package removes only CSS-owned files and legacy CSS files from old package
layouts. It does not remove `/usr/local/bin` or unrelated local files.

## Automatic Package Upgrade

The deb installs `cs-storage-auto-upgrade.timer`. It checks the GitHub latest
Release, downloads a newer `cs-storage_<version>_amd64.deb`, verifies the
`.sha256` asset when present, and installs it non-interactively. The script is
host-local only: it does not call Docker, does not create Swarm services, and
does not mutate other nodes. Network downloads and apt/dpkg install attempts
are retried with `CSS_UPGRADE_RETRY_ATTEMPTS` and `CSS_UPGRADE_RETRY_DELAY`;
concurrent runs are skipped through `/run/cs-storage-upgrade.lock`.
`/etc/cs-storage` config and secrets are preserved. During active delivery
testing the timer interval is `5s`; before final long-term delivery change
`OnUnitActiveSec` to `1min`.

Do not use Docker Swarm services, Stack workloads, or helper containers to
install or upgrade CSS host packages across nodes. Package installation is a
local host operation handled by apt/systemd on each node. Using Swarm to mutate
the hosts can disturb the same Swarm manager, gossip, and overlay paths that
the scenario tests are intended to validate. The Stack scenario harness is only
for post-install workload verification.

## Encryption Pipeline

`cs.crypt=true` protects node-local physical/cache storage only. Containers
still read and write plaintext, and the default WebDAV/S3 backend content is
plaintext for debugging, management, and restore workflows. The required
pipeline is rclone on the gocryptfs auto-decrypted mount/cache view. Rclone
must not read, cache, or sync the physical cipher directory directly.

## Common Failures

`--server-url is required for client`

The node is being installed as client-only and no existing daemon config was
found. Pass the reachable server URL.

`--node-secret or --node-secret-file is required for a fresh client install`

Use the `CSS_CLIENT_INSTALL_COMMAND` printed by the server/all installer, or
rerun the client installer with `--node-secret '<value>'`. Use
`--node-secret-file` only if your automation already placed the file locally.

`refusing to replace existing <secret>`

The target secret already exists and the provided value differs. Re-run without
the new value to reuse the current file, or pass `--force-secret-update` for an
intentional rotation.

`no free CSS server port in 18080-18100`

Pass `--server-port <port>` or `--server-addr <addr:port>`.

Interactive `Daemons using outdated libraries` package screen

This is the operating system `needrestart` prompt. Current installers suppress
it automatically. If an older install is already stuck on that screen, interrupt
that run and rerun the one-command installer from GitHub.

`perl: warning: Setting locale failed`

The apt/deb stage now runs with `LC_ALL=C` so missing host locales do not hide
the CSS install result in warning noise.

`N: Download is performed unsandboxed as root`

The installer now makes its temporary downloaded `.deb` readable by apt's `_apt`
user, so this warning should not appear on fresh runs.

## Compose/Stack Use

In existing Compose or Stack files, set the volume driver to `css`:

```yaml
volumes:
  data:
    driver: css
    driver_opts:
      cs.crypt: "true"
      cs.backup: "true"
```

The `cs.*` option names are unchanged.

## Delivery Scenario Test

Run the formal Stack workload test after installation:

```sh
sudo sh scripts/css-scenario-test-deploy.sh --clean --profile smoke --current-node
```

For multi-node validation after every client node is installed:

```sh
sudo sh scripts/css-scenario-test-deploy.sh --clean --profile full --all-ready-nodes
```

Reports are written to `reports/css-scenario-<run-id>/`. The stack schedules
only on nodes labelled by the deploy script and uses the host `css` driver.
`full` renders all 36 valid option combinations; missing prerequisites are
reported as `BLOCKED`, not hidden. This test stack is kept in the repository as
an acceptance tool; it is not installed into the production `.deb`.
