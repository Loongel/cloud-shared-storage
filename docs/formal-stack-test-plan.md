# Formal Stack Scenario Test Plan

This plan drives CSS from "installed system services" to delivery-ready
validation through Docker Swarm Stack workloads. The Stack tests application
volumes through the host `css` Docker VolumeDriver. It must not run the CSS
server, daemon, or plugin as workload containers.

## Goals

- Prove that the installed host services are usable by Docker Stack workloads.
- Cover every valid combination in `deploy/scenario-test/scenarios.tsv`.
- Produce a report that distinguishes product failures, missing prerequisites,
  and test harness failures.
- Keep tests non-destructive to unrelated stacks, nodes, labels, and volumes.
- Make reruns deterministic: a failed or interrupted run must not poison the
  next run.

## Architecture Authority

The authoritative design inputs are `技术方案.v0.txt` and `技术方案.v1.txt`.
Test failures must be fixed by preserving those designs, not by replacing the
storage pipeline with a different easier-to-test model.

Architecture invariants:

- CSS server and client components are host systemd services.
- The Docker VolumeDriver plugin is a thin proxy only; it must not run FUSE,
  rclone, GlusterFS, LiteFS, or backup processes.
- GlusterFS and LiteFS are production runtime components of CSS, not ad hoc
  test fixtures. The deb package and host installation path must install or
  make available their required binaries/packages, and the CSS systemd service
  model must manage their lifecycle. The current preferred implementation is
  daemon-managed per-volume child processes/mounts; split them into independent
  systemd units only if the daemon model cannot provide reliable supervision.
- S-side is the only component that stores backend WebDAV/S3 credentials.
- C-side rclone talks to the S-side gateway with JWT auth, not directly to the
  backend.
- `private` and `shared + single` use the single-write realtime chain described
  by the design: Docker volume path -> gocryptfs realtime encryption when
  enabled -> rclone VFS -> S-side reverse proxy.
- `shared + multi` uses GlusterFS/LiteFS/router for the consistency layer; rclone
  is the egress path after the local/distributed consistency layer, not the
  cross-node write coordinator.
- Fixes for encrypted realtime volumes must keep the gocryptfs + rclone VFS
  model unless the design documents are explicitly revised.

## Merged Delivery Execution Plan

This plan is the single execution path for delivery. New runtime findings are
merged back here instead of creating a competing plan.

1. Preserve the architecture from `技术方案.v0.txt` and `技术方案.v1.txt`:
   production CSS components are host services, the Docker VolumeDriver is only
   a thin proxy, S-side owns backend credentials, and C-side owns rclone,
   gocryptfs, GlusterFS, LiteFS, Kopia, and router orchestration.
2. Use `docs/scenario-test-design.md` as the scenario authority: all 36 valid
   combinations are requested by the `full` profile, `cs.backup` is strictly
   `true` or `false`, and invalid combinations are negative controls.
3. Use this file as the repair and evidence plan: run profiles in the order
   `smoke`, `core`, `backup-only`, `shared-multi-only`, then `full`; every
   failure must be classified as product, packaging/configuration, or harness.
4. Apply fixes at the production layer first. If GlusterFS, LiteFS, Kopia,
   gocryptfs, rclone, router, daemon, plugin, package dependencies, or systemd
   lifecycle behavior are wrong, fix the deb/systemd/daemon path rather than
   masking the issue in Stack workloads.
5. Keep Stack tests as application workloads only. They may create volumes,
   write/read files, exercise SQLite, and generate reports, but they must not
   launch CSS server, daemon, plugin, GlusterFS, or LiteFS as replacement
   product containers.
6. Treat service startup as part of delivery. The CSS plugin socket must be
   available early enough that Docker can restore existing `css` volumes during
   boot; daemon/plugin units must not wait on Docker in a way that creates a
   startup cycle.
7. Delivery is not complete until the reports and service evidence listed in
   "Pass Criteria For Delivery" exist for the final package/release candidate.

## Current Findings

These findings came from the first hd01 test attempts on 2026-05-26.

| Area | Finding | Classification | Required Fix |
| --- | --- | --- | --- |
| Node labels | `--current-node` selected hd01, but wawo01 still had `css.test.enabled=true` from an old run. | Harness defect | Deployment must clear all `css.test.*` labels before selecting nodes, and clear all labels on exit when requested. |
| Stale volumes | Existing `css_scenario_css_*` volumes were reused, so `flush=true` did not reset scenario state. | Harness defect | Clean mode must remove old task containers and known scenario volumes before deploying. |
| Backend path | Workload node name was `hd01`, while daemon backend node id was `hd01.netbird.cloud`; direct WebDAV checks looked at the wrong path. | Harness defect | Report must map workload node names to daemon `CS_NODE_ID` or explicit node-id metadata. |
| Encrypted realtime | `crypt=true` smoke mounted gocryptfs but `/data` was not writable in the workload. | Product or lifecycle defect | Reproduce on a fresh single encrypted volume and fix mount lifecycle/permission/path handling in the daemon. |
| Full profile prerequisites | `cs.backup=true`, `shared+multi+static`, and `shared+multi+sqlite/auto` require Kopia, Gluster, and LiteFS runtime config. | Product packaging/config gap until proved otherwise | Deb/install must provide Kopia/LiteFS binaries and Gluster packages or clear install instructions; daemon/systemd must own runtime process supervision. Preflight may mark rows `BLOCKED` only with exact missing package/config evidence. |
| Report wait | A failed full run appeared to wait too long after create/mount rejection. | Harness defect | Reporter must treat terminal task states and service rejections as complete, then collect partial results. |

## Capability Layers

The matrix is not one flat test. It is four capability layers with different
runtime requirements.

| Layer | Scenarios | Product Capability | Required Host Config |
| --- | --- | --- | --- |
| L1 realtime file | private/shared + single + auto + plaintext/encrypted | Rclone WebDAV mount, optional gocryptfs, Docker plugin path | `CS_SERVER_URL`, `CS_NODE_ID`, `CS_NODE_SECRET_KEY`, `CS_GOCRYPTFS_PASSWORD` for encrypted |
| L2 shared single variants | shared + single + static/sqlite/auto + plaintext/encrypted | Same user-visible semantics as single writer; engine option should not break single-write path | Same as L1 |
| L3 backup | any `cs.backup=true` | Kopia snapshot lifecycle and report restore evidence | `CS_KOPIA_CONFIG_PATH` or `CS_KOPIA_REPOSITORY`, password if needed |
| L4 shared multi | shared + multi + static/sqlite/auto | Gluster, LiteFS, or router-backed shared write semantics | `CS_GLUSTER_REMOTE`; `CS_LITEFS_ADVERTISE_URL`; optional Consul coordinator for real multi-node LiteFS |

The required host config is part of the production installation contract. Stack
tests may create disposable volumes and workloads, but they must not substitute
containerized GlusterFS/LiteFS sidecars for missing host-system capabilities.
If a component is missing, classify the row as a packaging/configuration defect
unless the scenario is explicitly scoped to an optional topology.

## Profiles

| Profile | Purpose | Must Pass Before |
| --- | --- | --- |
| `smoke` | Four L1 scenarios: private/shared single x plaintext/encrypted. Fast check for install and driver path. | Any wider matrix run |
| `core` | All non-backup=true scenarios that are valid for current prerequisites. | Full report |
| `backup-only` | All `cs.backup=true` scenarios after Kopia preflight passes. | Full report with backup enabled |
| `shared-multi-only` | All shared multi scenarios after Gluster/LiteFS preflight passes. | Full report with multi-write enabled |
| `full` | Complete 36-row acceptance matrix. | Delivery summary |

## Preflight Design

Add a first-class preflight phase before Stack deploy.

The preflight must collect:

- Swarm manager status and selected nodes.
- Per-node CSS services: `cs-storage-daemon`, `cs-storage-plugin`, plugin socket.
- Deb/systemd ownership evidence for shared-multi components: installed CSS
  package version, `litefs` binary path/version, `mount.glusterfs` path,
  `glusterd.service` state when local Gluster management is required, and
  daemon env values used to supervise those processes.
- Driver create/remove for a disposable default volume.
- Backend credentials and a direct WebDAV read/write/delete probe under a test prefix.
- Daemon identity mapping: Docker hostname, `CS_NODE_ID`, backend storage prefix.
- Encrypted mount probe: disposable `cs.crypt=true` volume, write/read/remove.
- Kopia availability and repository connectivity when backup=true scenarios are requested.
- Gluster remote availability when static shared multi scenarios are requested.
- LiteFS runtime config and port strategy when sqlite/auto shared multi scenarios are requested.

Preflight output must be saved as `preflight.tsv` and summarized in `report.md`.

## Scenario Execution Design

The harness should render only scenarios whose prerequisites are satisfied,
unless the user explicitly asks to include blocked rows.

Execution rules:

- Always clear old `css.test.*` labels from all Swarm nodes before selecting
  test nodes.
- With `--current-node`, only the current Swarm node receives the test label.
- With `--clean`, remove old stack services, old task containers, and known
  `css_scenario_css_*` volumes before deploy.
- Use a unique stack name or unique volume prefix per run when possible.
- Keep `flush=true` in driver opts for scenario volumes, but do not rely on it
  as the only cleanup mechanism.
- Archive the exact rendered Stack file and scenario table in the report dir.
- Do not let one blocked capability hide unrelated L1/L2 failures.

## Expected Results By Scenario Type

| Type | Workload Action | Expected Local State | Expected Backend State |
| --- | --- | --- | --- |
| private single plaintext | Each node writes its own marker | Node sees only its own marker | Plaintext marker exists under that node's daemon id |
| private single encrypted | Each node writes its own marker | Node sees only its own marker | Plaintext marker absent; gocryptfs cipher state exists |
| shared single plaintext | Deterministic writer writes one marker | Every selected node sees writer marker | Plaintext writer marker exists under writer daemon id |
| shared single encrypted | Deterministic writer writes one marker | Every selected node sees writer marker | Plaintext marker absent; cipher state exists |
| shared multi static | Every node writes a marker | Every node sees all node markers | Plaintext or encrypted backend follows `cs.crypt` |
| shared multi sqlite | Every node inserts one SQLite row | `PRAGMA integrity_check=ok`, row count equals node count | Backend DB or encrypted state follows `cs.crypt` |
| shared multi auto | File marker plus SQLite probe | File and SQLite expectations both pass | Backend follows selected plaintext/encrypted mode |
| backup enabled | Normal workload plus snapshot | Workload passes locally | Kopia snapshot found and restore matches mounted plaintext view |

Backend paths are volume-scoped inside the node sandbox:

- Plaintext marker: `nodes/<node-id>/volumes/<docker-volume>/css-scenario-test/<run-id>/<scenario>/writers/<node>.txt`
- Encrypted state: `nodes/<node-id>/volumes/<docker-volume>/cipher/gocryptfs.conf`

This preserves the S-side node sandbox model from the technical design while
preventing independent Docker volumes on the same node from sharing one
gocryptfs cipher root.

## Failure Classification

Every row must end in one of these states:

- `PASS`: workload, backend, and backup checks all satisfy expectations.
- `FAIL`: product behavior or harness expectation failed despite prerequisites.
- `BLOCKED`: scenario was requested but a declared prerequisite is absent.
- `SKIP`: scenario was intentionally not requested by profile or prerequisites.

Do not convert `FAIL` to `BLOCKED` after the fact. The reporter may mark
service creation failures as `BLOCKED` only when the error matches a declared
missing prerequisite.

## Repair Order

1. Harness hygiene:
   - clear all test labels before selection;
   - clean task containers and scenario volumes;
   - make reporter terminate cleanly on rejected/failed services;
   - map Docker node names to daemon node ids for backend checks.

2. L1 smoke correctness:
   - rerun plaintext single scenarios;
   - reproduce encrypted realtime failure with a disposable volume;
   - fix daemon mount lifecycle if gocryptfs/rclone mountpoint is not stable;
   - rerun smoke until all 4 scenario rows and controls pass.

3. Core non-backup matrix:
   - render L1/L2 non-backup rows separately from shared multi;
   - ensure single-write engine options do not require unnecessary Gluster/LiteFS config;
   - rerun `core` and classify any true shared-multi prerequisites as `BLOCKED`.

4. Backup capability:
   - verify Kopia is available from the deb/systemd installation path;
   - create a test-local Kopia filesystem repository under `/var/lib/cs-storage/test-kopia`;
   - configure daemon via a drop-in or env update without replacing secrets;
   - rerun backup-only and verify snapshot plus restore evidence.

5. Shared multi capability:
   - audit the deb and installer path for GlusterFS/LiteFS package/binary
     availability before treating missing runtime as a test-only blocker;
   - decide whether hd01-only tests should use a single-node Gluster/LiteFS setup or require multi-node clients;
   - provision Gluster/LiteFS through CSS host service configuration, preferably
     daemon-managed per-volume child processes; do not add production
     containerized sidecars to satisfy tests;
   - avoid parallel LiteFS port collisions by serializing sqlite scenarios or using per-volume config paths/ports;
   - rerun shared-multi-only.

6. Full acceptance:
   - run `full` on hd01;
   - after other nodes are reinstalled and verified, run `full --all-ready-nodes`;
   - archive reports and push test harness changes to GitHub.

## Pass Criteria For Delivery

The project is test-delivery complete when:

- `css-install-all.sh` leaves hd01 with all three systemd services active/enabled.
- `smoke` has zero failures and zero blocked rows on hd01.
- `core` has zero failures; blocked rows are allowed only when explicitly tied to missing L4 prerequisites.
- `backup-only` passes after Kopia preflight is enabled.
- `shared-multi-only` passes in the intended topology, with GlusterFS/LiteFS
  installed and supervised through the deb/systemd delivery path, or is
  documented as requiring multi-node provisioning with exact missing host
  config evidence.
- `full` report clearly shows all 36 scenarios as `PASS`, or separates unavailable optional capabilities as `BLOCKED` with exact missing prerequisites.
- `report.md`, `results.tsv`, `controls.tsv`, `preflight.tsv`, `service-logs.txt`, and `stack.rendered.yml` are archived for the final run.
