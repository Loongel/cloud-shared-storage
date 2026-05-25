# CSS Scenario Stack Test Guide

This test suite validates the formal host systemd deployment through Docker
Swarm Stack workloads. It is an acceptance tool kept in the repository, not a
production `.deb` runtime payload. It does not run CS-Storage server, daemon, or
plugin as containers. Each workload mounts a real Docker volume with driver
`css`, writes test data, reads it back, and prints a machine-readable result.
The host report script also checks the WebDAV backend directly when it can read
the server env.

## Quick Local Test

Run this on a Swarm manager after installing `cs-storage-server.service`,
`cs-storage-daemon.service`, and `cs-storage-plugin.service` on the local node:

```sh
sudo sh scripts/css-scenario-test-deploy.sh --clean --current-node
```

The default stack labels only the current node with
`node.labels.css.test.enabled=true`, then deploys:

- `private_plain`: `cs.mode=private`, `cs.write=single`, `cs.crypt=false`.
- `private_encrypted`: `cs.mode=private`, `cs.write=single`, `cs.crypt=true`.
- `shared_single_plain`: `cs.mode=shared`, `cs.write=single`, `cs.crypt=false`.
- `shared_single_encrypted`: `cs.mode=shared`, `cs.write=single`, `cs.crypt=true`.

Reports are written under `reports/css-scenario-<run-id>/`.

Add `--clear-labels` when you want the deploy script to remove the temporary
`css.test.*` node labels after the report is generated.

## Multi-Node Test

After every target node has the host client services installed and the Docker
driver socket exists at `/run/docker/plugins/css.sock`, run:

```sh
sudo sh scripts/css-scenario-test-deploy.sh --clean --all-ready-nodes
```

The workload containers run globally on nodes labelled
`css.test.enabled=true`. They write one marker per node and then list visible
markers. Shared scenarios expect the number of visible writers to match the
selected node count.

## Optional Scenarios

Backup and shared-multi SQLite probes are intentionally disabled by default
because they require extra daemon-side configuration.

```sh
sudo sh scripts/css-scenario-test-deploy.sh --clean --all-ready-nodes --enable-backup
sudo sh scripts/css-scenario-test-deploy.sh --clean --all-ready-nodes --enable-sqlite
```

`--enable-backup` labels selected nodes with `css.test.backup=true` so the
`cs.backup=auto` service can schedule. It requires a working Kopia repository
config in the daemon environment.

`--enable-sqlite` labels selected nodes with `css.test.sqlite=true` so the
`cs.mode=shared`, `cs.write=multi`, `cs.engine=sqlite` probe can schedule. It
requires the LiteFS/Consul settings needed by this deployment mode.

## Report Columns

`results.tsv` contains:

- `scenario`: test scenario name.
- `node`: Swarm node hostname reported to the container.
- `service`: Swarm service name.
- `volume`: logical stack volume name.
- `driver_opts`: CSS driver options under test.
- `operations`: operations performed inside the mounted volume.
- `expected`: expected writer count or behavior.
- `actual_volume_state`: writer files seen from the mounted volume.
- `actual_backend_state`: direct WebDAV check result when available.
- `status`: `PASS` or `FAIL`.
- `notes`: short failure reason or `ok`.

For encrypted scenarios, the direct backend check expects the plaintext marker
path to be absent and `cipher/gocryptfs.conf` to exist under the node sandbox.
Secret values are never printed.
