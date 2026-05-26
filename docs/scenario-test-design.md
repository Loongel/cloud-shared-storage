# CSS Post-Install Scenario Test Design

This document defines the acceptance test matrix before rewriting the Stack
file. The test target is the formal host systemd deployment:

- `cs-storage-server.service`
- `cs-storage-daemon.service`
- `cs-storage-plugin.service`
- Docker VolumeDriver name: `css`

The Stack is only an application workload harness. It must not run CSS server,
daemon, or plugin containers.

GlusterFS and LiteFS are part of the installed CSS host runtime for
`shared+multi` volumes. Scenario tests may verify their behavior through Docker
workloads, but they must not replace them with test-only containers. The CSS deb
package/installer and systemd service model must provide the binaries,
dependencies, configuration, and lifecycle supervision. The current expected
implementation is `cs-storage-daemon.service` launching and monitoring
per-volume GlusterFS mounts, LiteFS mounts, and the auto router; independent
systemd units are acceptable only if that daemon-managed model is insufficient.

## Parameter Space

Supported driver options:

- `cs.mode`: `private`, `shared`
- `cs.write`: `single`, `multi`
- `cs.engine`: `auto`, `static`, `sqlite`
- `cs.crypt`: `false`, `true`
- `cs.backup`: `true`, `false`
- `flush`: `false`, `true`

Valid product combinations:

- `private + single + any engine + any crypt + any backup`: 12 scenarios.
- `shared + single + any engine + any crypt + any backup`: 12 scenarios.
- `shared + multi + any engine + any crypt + any backup`: 12 scenarios.

Invalid combinations:

- `private + multi + any engine + any crypt + any backup`: must fail at volume
  creation with `cs.write=multi requires cs.mode=shared`.
- Invalid enum values for mode, write, engine, crypt, and backup must fail.
- `flush` from labels or Compose metadata must fail; destructive `flush` is
  allowed only as explicit `driver_opts.flush`.

Effective pipeline semantics:

- `private`: `cs.engine` is accepted but does not change the rclone pipeline.
- `shared + single`: `cs.engine` is accepted but does not change the
  shared-single rclone pipeline.
- `shared + multi + static`: GlusterFS path.
- `shared + multi + sqlite`: LiteFS path.
- `shared + multi + auto`: router path, SQLite files route to LiteFS and normal
  files route to GlusterFS.
- `cs.crypt=true`: backend must not expose plaintext path or plaintext content.
- `cs.backup=true`: Kopia must snapshot and restore the mounted plaintext view.

## Full Valid Matrix

Each requested valid row must produce a result. Rows whose prerequisites are
missing must be reported as `BLOCKED` with the missing requirement, not silently
omitted and not counted as pass.

| ID | mode | write | engine | crypt | backup | Workload |
| --- | --- | --- | --- | --- | --- | --- |
| P-S-A-P-N | private | single | auto | false | false | private-file |
| P-S-A-E-N | private | single | auto | true | false | private-file |
| P-S-ST-P-N | private | single | static | false | false | private-file |
| P-S-ST-E-N | private | single | static | true | false | private-file |
| P-S-SQ-P-N | private | single | sqlite | false | false | private-file |
| P-S-SQ-E-N | private | single | sqlite | true | false | private-file |
| P-S-A-P-B | private | single | auto | false | true | private-file + backup |
| P-S-A-E-B | private | single | auto | true | true | private-file + backup |
| P-S-ST-P-B | private | single | static | false | true | private-file + backup |
| P-S-ST-E-B | private | single | static | true | true | private-file + backup |
| P-S-SQ-P-B | private | single | sqlite | false | true | private-file + backup |
| P-S-SQ-E-B | private | single | sqlite | true | true | private-file + backup |
| S-S-A-P-N | shared | single | auto | false | false | shared-single-file |
| S-S-A-E-N | shared | single | auto | true | false | shared-single-file |
| S-S-ST-P-N | shared | single | static | false | false | shared-single-file |
| S-S-ST-E-N | shared | single | static | true | false | shared-single-file |
| S-S-SQ-P-N | shared | single | sqlite | false | false | shared-single-file |
| S-S-SQ-E-N | shared | single | sqlite | true | false | shared-single-file |
| S-S-A-P-B | shared | single | auto | false | true | shared-single-file + backup |
| S-S-A-E-B | shared | single | auto | true | true | shared-single-file + backup |
| S-S-ST-P-B | shared | single | static | false | true | shared-single-file + backup |
| S-S-ST-E-B | shared | single | static | true | true | shared-single-file + backup |
| S-S-SQ-P-B | shared | single | sqlite | false | true | shared-single-file + backup |
| S-S-SQ-E-B | shared | single | sqlite | true | true | shared-single-file + backup |
| S-M-A-P-N | shared | multi | auto | false | false | shared-multi-auto |
| S-M-A-E-N | shared | multi | auto | true | false | shared-multi-auto |
| S-M-ST-P-N | shared | multi | static | false | false | shared-multi-file |
| S-M-ST-E-N | shared | multi | static | true | false | shared-multi-file |
| S-M-SQ-P-N | shared | multi | sqlite | false | false | shared-multi-sqlite |
| S-M-SQ-E-N | shared | multi | sqlite | true | false | shared-multi-sqlite |
| S-M-A-P-B | shared | multi | auto | false | true | shared-multi-auto + backup |
| S-M-A-E-B | shared | multi | auto | true | true | shared-multi-auto + backup |
| S-M-ST-P-B | shared | multi | static | false | true | shared-multi-file + backup |
| S-M-ST-E-B | shared | multi | static | true | true | shared-multi-file + backup |
| S-M-SQ-P-B | shared | multi | sqlite | false | true | shared-multi-sqlite + backup |
| S-M-SQ-E-B | shared | multi | sqlite | true | true | shared-multi-sqlite + backup |

Abbreviations:

- `A`: `auto`
- `ST`: `static`
- `SQ`: `sqlite`
- `P`: plaintext, `cs.crypt=false`
- `E`: encrypted, `cs.crypt=true`
- `N`: `cs.backup=false`
- `B`: `cs.backup=true`

## Workload Design

Every marker must be deterministic. The expected content is derived from
`run_id`, `scenario_id`, `node`, `role`, and option values. Each marker has a
SHA256 checksum so the reporter can compare exact bytes without printing any
secret.

Common per-scenario layout inside the mounted volume:

```text
/css-scenario-test/<run_id>/<scenario_id>/
  manifest.json
  writers/<node>.json
  checksums/<node>.sha256
  readers/<node>.json
  sqlite/main.db
  sqlite/integrity/<node>.txt
```

The Stack should use separate write and verify phases:

1. Writer phase writes deterministic data and exits.
2. Reporter waits for expected writer task completion.
3. Reader/verify phase runs on every selected node and validates local mount
   contents.
4. Reporter performs direct WebDAV and optional Kopia checks.

Sleeping alone is not sufficient; verify workloads must poll until either the
expected content appears or a timeout is reached.

### Private Single Workload

Target scenarios: all `P-S-*`.

Node behavior:

- Every selected node writes only its own marker:
  `writers/<node>.json`.
- Every node reads back its own marker and checksum.
- Every node verifies that markers from other selected nodes are not visible in
  its mounted volume.

Expected local volume state:

- Own marker exists and exact checksum matches.
- Other nodes' markers are absent.

Expected WebDAV backend state:

- `crypt=false`: backend plaintext path for that node contains the exact marker
  bytes.
- `crypt=true`: backend plaintext marker path is absent; encrypted cipher state
  exists; plaintext marker filename and marker content must not be visible in
  direct backend checks.

Expected cross-node result:

- Isolation is required. If node A can see node B's private marker, fail.

### Shared Single Workload

Target scenarios: all `S-S-*`.

Writer policy:

- Exactly one writer node is selected deterministically, usually the
  lexicographically first selected node or the node labelled
  `css.test.writer=true`.
- Only that writer writes `writers/<writer>.json`.
- All selected nodes run readers.

Expected local volume state:

- Writer node reads its own marker.
- Every reader node sees the writer marker with the exact checksum.
- Non-writer nodes must not create writer markers.

Expected WebDAV backend state:

- `crypt=false`: backend contains exactly the writer marker for the shared
  volume namespace and the bytes match.
- `crypt=true`: backend plaintext marker path is absent; encrypted cipher state
  exists for the shared volume namespace.

Expected cross-node result:

- Shared-single proves shared read visibility with one writer. If only the
  writer node sees the data, fail.

### Shared Multi Static Workload

Target scenarios: `S-M-ST-*`.

Prerequisites:

- Daemon has valid Gluster configuration from the host CSS installation.
- `mount.glusterfs` and required Gluster packages are installed by the deb
  dependency/install path or are otherwise present before the test starts.
- Periodic rclone sync is configured when backend verification is required.

Node behavior:

- Every selected node writes `writers/<node>.json` concurrently.
- Every selected node waits for all selected node markers.
- Every selected node verifies all marker checksums.

Expected local volume state:

- Each node sees exactly the full selected node set.
- No checksum mismatch.

Expected WebDAV backend state:

- `crypt=false`: after sync settle, backend contains all node markers with exact
  bytes.
- `crypt=true`: plaintext marker paths are absent; encrypted state exists.

### Shared Multi SQLite Workload

Target scenarios: `S-M-SQ-*`.

Prerequisites:

- Daemon has valid LiteFS/lease configuration from the host CSS installation.
- `litefs` is installed by the CSS deb package or otherwise available to
  `cs-storage-daemon.service` before the test starts.
- Test container has `sqlite3`.
- Periodic rclone sync is configured when backend verification is required.

Node behavior:

- Every selected node inserts one deterministic row into
  `sqlite/main.db`.
- Writes use `PRAGMA busy_timeout` and bounded retries.
- Every selected node runs:
  - `PRAGMA integrity_check`
  - `SELECT COUNT(*)`
  - checksum query over deterministic rows

Expected local volume state:

- `integrity_check` returns `ok` on every node.
- Row count equals selected node count.
- Every expected node row exists exactly once.

Expected WebDAV backend state:

- `crypt=false`: after sync settle, the backend database can be downloaded and
  `PRAGMA integrity_check` returns `ok`; row count matches.
- `crypt=true`: plaintext database path is absent; encrypted state exists.

### Shared Multi Auto Workload

Target scenarios: `S-M-A-*`.

Prerequisites:

- Both Gluster and LiteFS host-runtime prerequisites are met.
- `cs-storage-router` is installed by the CSS deb package and supervised by the
  daemon as part of the per-volume auto pipeline.
- Periodic rclone sync is configured when backend verification is required.

Node behavior:

- Run the shared multi static marker test for normal files.
- Run the shared multi SQLite test for `sqlite/main.db`.

Expected local volume state:

- Normal marker files are visible on every node.
- SQLite rows are visible on every node.
- SQLite integrity is `ok`.

Expected backend state:

- Same as static plus SQLite expectations, adjusted for encryption.

### Backup Enabled Workload

Target scenarios: every row with `cs.backup=true`.

Prerequisites:

- Daemon has `CS_KOPIA_CONFIG_PATH` or `CS_KOPIA_REPOSITORY`.
- Kopia password/config are valid.
- Snapshot interval is short enough for the test or the test triggers remove to
  force a final snapshot.

Expected backup state:

- At least one Kopia snapshot exists for the volume mountpoint.
- Latest snapshot description includes `cs-storage:<volume>`.
- Restore latest snapshot to a temporary directory.
- Restored contents match the mounted plaintext view for the scenario.

If prerequisites are absent and backup=true scenarios are requested, report
`BLOCKED`, not `PASS`.

## Default, Precedence, Flush, And Negative Tests

These are host-side control tests, not long-running application workloads.

| ID | Purpose | Operation | Expected |
| --- | --- | --- | --- |
| CTRL-DEFAULT | No opts uses defaults | Create volume with driver `css` and no opts | plan is private-rclone, crypt=true, backup=false; plaintext backend marker absent |
| CTRL-ALIASES | Non-`cs.` aliases are accepted | Create with `mode=shared`, `write=single`, `crypt=false` | normalized options match `cs.*` equivalents |
| CTRL-LABEL-RENDER | Compose labels render to driver opts | run `cs-storage-admin render-compose` | supported labels appear in `driver_opts` |
| CTRL-OPTS-PRECEDENCE | explicit opts override labels | label says shared, driver opts say private | created plan follows opts |
| CTRL-FLUSH-OPTS | `flush=true` from opts is honored | write old marker, recreate with flush | old marker absent |
| CTRL-FLUSH-LABEL | `flush` from label is rejected | render/deploy label-sourced flush | expected error |
| NEG-PRIVATE-MULTI | invalid mode/write pair | create `private+multi` for each engine/crypt/backup axis | expected validation error |
| NEG-BAD-ENUMS | invalid enum values | create bad mode/write/engine/crypt/backup | expected validation error |

## Report Schema

The final report must contain both machine-readable JSONL/TSV and a Markdown
summary.

Per run:

- run id
- git commit
- stack name
- selected node count
- selected node names
- selected writer node name for single-writer scenarios
- server URL
- driver socket path
- backend check enabled/disabled
- WebDAV backend base path, redacted
- start/end time
- final pass/fail/skip/block counts

Per scenario:

- scenario id
- requested driver options
- normalized option values
- expected pipeline kind and components
- actual plan from daemon `/v1/plan`
- prerequisite status
- workload type
- writer policy
- expected node set
- actual writer node set
- actual reader node set
- local volume verdict
- backend verdict
- backup verdict
- final status: `PASS`, `FAIL`, `SKIP`, or `BLOCKED`
- failure reason

Per node:

- node name
- role: private-writer, shared-writer, reader, sqlite-writer, verifier
- service/task/container id
- volume name
- mountpoint reported by Docker
- operations performed
- expected marker checksum
- actual marker checksum
- visible marker set
- visible relative path list for the scenario root
- missing marker set
- unexpected marker set
- SQLite integrity result
- SQLite expected rows
- SQLite actual rows
- status and error

Per WebDAV backend check:

- backend namespace type: private-node or shared-volume
- expected plaintext paths
- actual HTTP status for each expected path
- expected checksum
- actual checksum
- encrypted plaintext-path absence status
- encrypted cipher-state presence status
- backend listing summary
- status and error

Per backup check:

- Kopia config/repository present
- snapshot count before/after
- selected latest snapshot id/time
- restore target
- restored checksum set
- status and error

## Pass/Fail Rules

Overall run passes only if:

- Every requested valid scenario is `PASS`.
- Every requested negative scenario fails with the expected validation error.
- No required scenario is silently missing.
- Every selected node reports for every scenario where it is expected.
- Backend checks match encryption expectations.
- Backup scenarios pass when requested with Kopia prerequisites configured.

`SKIP` is allowed only for scenarios not requested by the selected profile.
`BLOCKED` means the scenario was requested but prerequisites are missing; a
blocked scenario must make the overall run non-pass for formal delivery.

## Proposed Profiles

- `core`: all non-backup valid scenarios, 18 rows, plus defaults and negative
  controls.
- `full`: all 36 valid rows plus defaults, flush, precedence, and negative
  controls.
- `backup-only`: all `cs.backup=true` rows.
- `shared-multi-only`: `S-M-*` rows for Gluster/LiteFS/router validation.

Formal delivery should use `full` after every dependency is configured. During
incremental rollout, `core` can be used to identify missing shared-multi or
Kopia prerequisites without pretending they passed.
