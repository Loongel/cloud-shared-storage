# CSS Scenario Stack Test Guide

This test suite validates the formal host systemd deployment through Docker
Swarm Stack workloads. It is a repository acceptance tool, not a production
`.deb` runtime payload, and it does not run CS-Storage server, daemon, or plugin
as containers.

The harness renders a Stack from `deploy/scenario-test/scenarios.tsv`. The
committed `deploy/stack/css-scenario-test.yml` is the full rendered matrix.

## Profiles

- `full`: all 36 valid combinations of mode/write/engine/crypt/backup, plus
  host-side negative and control tests.
- `core`: all 18 non-backup combinations, plus negative and control tests.
- `smoke`: four fast realtime scenarios: private/shared-single x plaintext/encrypted.
- `backup-only`: all `cs.backup=true` scenarios.
- `shared-multi-only`: all `shared + multi` engine scenarios.

Requested scenarios with missing prerequisites are reported as `BLOCKED`. A
formal run is successful only when there are no `FAIL` or `BLOCKED` rows.

## Quick Local Test

```sh
sudo sh scripts/css-scenario-test-deploy.sh \
  --clean \
  --profile smoke \
  --current-node \
  --clear-labels
```

## Multi-Node Formal Test

After every target node has the host client services installed and the Docker
driver socket exists at `/run/docker/plugins/css.sock`, first confirm every
Swarm node is Ready and Docker logs are quiet for memberlist/raft errors. Do
not treat a run that silently excludes a Down node as delivery evidence.

```sh
sudo sh scripts/css-scenario-test-deploy.sh \
  --clean \
  --profile full \
  --all-ready-nodes \
  --clear-labels
```

For SQLite workloads, use a workload image that contains `sqlite3`, for example:

```sh
CSS_TEST_SQLITE_IMAGE=<image-with-sqlite3> \
sudo sh scripts/css-scenario-test-deploy.sh --clean --profile full --all-ready-nodes
```

## Swarm Stability Guard

The harness refuses to deploy when any Swarm node is not Ready, recent Docker
logs show memberlist/raft instability, or the rendered Stack would create too
many service-node tasks at once. This is intentional. `core` and `full` can
otherwise amplify NetBird UDP 7946 gossip instability and overlay endpoint
churn.

Defaults:

- `CSS_TEST_MAX_TASKS_PER_DEPLOY=24`
- `--allow-large-deploy` is for controlled diagnostics only.
- `--allow-unstable-swarm` is for failure capture only.

The harness no longer starts a global privileged cleanup helper. `--clean`
removes the test Stack and local manager-side test volumes only; per-node stale
state must be handled by the CSS driver `flush=true` path or by explicit local
operator cleanup.

## Report Files

Reports are written under `reports/css-scenario-<run-id>/`:

- `results.tsv`: one row per scenario/node result, including requested options,
  expected/actual visible marker sets, SQLite checks, WebDAV check, backup check,
  status, and notes.
- `controls.tsv`: negative and control tests for invalid combinations, bad enum
  values, and destructive `flush` label rejection.
- `report.md`: human-readable summary.
- `service-logs.txt`: raw workload logs.
- `stack.rendered.yml`: exact Stack file used for the run.

## What Is Verified

- Private single-write volumes: each node writes and reads only its own marker;
  other nodes' markers must not be visible.
- Shared single-write volumes: one deterministic writer writes, all selected
  nodes must read that writer's marker.
- Shared multi static volumes: every node writes a marker and every node must
  see all markers.
- Shared multi SQLite volumes: every node inserts a deterministic SQLite row;
  every node must report `PRAGMA integrity_check=ok` and the expected row count.
- Shared multi auto volumes: normal marker files plus SQLite checks.
- WebDAV backend: direct backend GET must match the expected marker checksum in
  the default remote mode, for both `cs.crypt=false` and `cs.crypt=true`.
- Local encryption: for `cs.crypt=true`, rclone uses the gocryptfs decrypted
  mount/cache view as input; tests must not treat the cipher directory as the
  rclone source, and must not treat plaintext WebDAV content as an encryption
  failure in the current default remote mode.
- Backup enabled: Kopia prerequisites and snapshots are checked; missing config is
  `BLOCKED`.

See `docs/scenario-test-design.md` for the complete matrix and pass/fail rules.
