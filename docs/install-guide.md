# CSS Install Guide

Cloud Shared Storage (CSS) installs as host systemd services. The Docker volume
driver name is `css`.

Use the role-specific wrappers for normal installs:

- `css-install-server.sh`: server gateway only.
- `css-install-client.sh`: client daemon plus Docker VolumeDriver plugin only.
- `css-install-all.sh`: server plus client on the same node.

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
a filled client one-liner using the selected public server URL. It still points
to `--node-secret-file /etc/cs-storage/secrets/node_secret`; copy that file from
the server to the same path on each client before running the command.

Client-only fresh install requires the server URL and the exact `node_secret`
from the server:

```sh
curl -fsSL https://raw.githubusercontent.com/Loongel/cloud-shared-storage/main/scripts/css-install-client.sh \
  | sudo sh -s -- \
  --server-url http://<server-netbird-fqdn-or-wt0-ip>:<server-port> \
  --node-secret-file /etc/cs-storage/secrets/node_secret
```

`node_secret` is the shared server/client authentication secret, not the node's
identity. The node id defaults to the NetBird FQDN from `netbird status`, then
falls back to the host name, unless you pass `--node-id`. Copy
`/etc/cs-storage/secrets/node_secret` from the server node to this same path on
each client, or pass the value with `--node-secret '<value>'`.

Server plus client on the same node requires backend storage details only. The
local client URL is inferred from the same NetBird-facing server URL:

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

If an existing `/etc/cs-storage/server.env` or `daemon.env` is present, repeat
installs reuse values from those files instead of choosing new values.

## Secret Lifecycle

`node_secret` authenticates clients to the server.

- Server/all generates it only on first install when absent.
- Client-only never generates it.
- Every client must use the same `node_secret` as the server.
- Back up `/etc/cs-storage/secrets/node_secret` immediately after first server
  install.

`gocryptfs_password` decrypts encrypted volumes.

- Client/all generates it only on first install when absent.
- Existing file is reused on repeat install.
- Changing it after encrypted volumes exist makes old encrypted data unreadable.
- Back up `/etc/cs-storage/secrets/gocryptfs_password` before using encrypted
  volumes.

Backend credentials are never generated. Fresh server/all install requires either:

- `--backend-auth-header-file`, or
- `--backend-user-file` plus `--backend-password-file`, or their inline value
  equivalents.

The installer never prints secret values. It prints only file paths and SHA256
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

## Common Failures

`--server-url is required for client`

The node is being installed as client-only and no existing daemon config was
found. Pass the reachable server URL.

`--node-secret or --node-secret-file is required for a fresh client install`

Copy the server's `/etc/cs-storage/secrets/node_secret` to the client through a
secure channel, then rerun with `--node-secret-file`.

`refusing to replace existing <secret>`

The target secret already exists and the provided value differs. Re-run without
the new value to reuse the current file, or pass `--force-secret-update` for an
intentional rotation.

`no free CSS server port in 18080-18100`

Pass `--server-port <port>` or `--server-addr <addr:port>`.

## Compose/Stack Use

In existing Compose or Stack files, set the volume driver to `css`:

```yaml
volumes:
  data:
    driver: css
    driver_opts:
      cs.crypt: "true"
      cs.backup: "auto"
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
