# Migration Manager

This is the operator guide for the Abird migration drain. It explains what the
migration manager gates, how to toggle it manually, and how to use
`data-migrator` for live cutovers.

## Model

`services.migration-manager` is a runtime drain for repo-managed app services on
a host. It is not a full host quarantine mechanism.

The only live state is the transient gate marker:

```text
/run/migration-manager/gate
```

When the file exists, the host is drained:

- migration-manager-managed system services are stopped and blocked from
  cold-starting;
- registered native `systemd.user` services are stopped and blocked from
  cold-starting;
- registered native `systemd.user` targets, including managed and per-service
  ready targets, are stopped and blocked from cold-starting;
- podman-compose workloads drain through their generated user service units.

When the file is absent, the host is resumed:

- system services marked `startOnResume = true` can be started again;
- registered native `systemd.user` services marked `startOnResume = true` can be
  started again;
- registered native `systemd.user` targets marked `startOnResume = true`, such
  as `<user>-managed.target`, are started to converge the user graph.

The normal declarative state is:

```nix
services.migration-manager.state = "runtime";
```

`"runtime"` means Nix switches do not overwrite the live gate state during the
current boot. A reboot clears `/run` unless a generation explicitly sets
`services.migration-manager.state = "on"`.

## Manual Gate Control

Use this when you need to drain or resume a host from the repo without running a
full data migration.

From the repo root, check the remote gate:

```bash
nix run .#migration-manager -- remote status --host HOST
```

Drain the remote host:

```bash
nix run .#migration-manager -- remote on --host HOST
```

Re-apply the current remote gate state without changing it:

```bash
nix run .#migration-manager -- remote apply --host HOST
```

Resume the remote host:

```bash
nix run .#migration-manager -- remote off --host HOST
```

`HOST` is a nixbot host name from `hosts/nixbot.nix`. The remote host must
already have a generation with `services.migration-manager` installed, because
the remote command calls:

```bash
sudo /run/current-system/sw/bin/migration-manager on
```

When already logged into the target host, use the local installed command
directly:

```bash
sudo /run/current-system/sw/bin/migration-manager status
sudo /run/current-system/sw/bin/migration-manager on
sudo /run/current-system/sw/bin/migration-manager apply
sudo /run/current-system/sw/bin/migration-manager off
```

## Data Migrator Concepts

`data-migrator` copies host state paths declared in
`pkgs/tools/data-migrator/profiles.nix`. It can do plain file-copy migrations or
Incus instance/project migrations.

Important names:

- `--source-host` is the SSH host or address used for reading data.
- `--target-host` is the SSH host used for writing data.
- `--source-drain-host` is the nixbot host whose migration-manager gate should
  be turned on before the final copy.
- `--target-drain-host` is the nixbot host whose target generation should be
  bootstrapped drained, then resumed after the final copy.

Those are often the same strings, but not always. Abird profiles commonly use an
IP address as `source_host`; that works for rsync, but drain/resume should use
the nixbot host name.

A full file-copy migration does this:

1. deploy the target into a temporary drained generation;
2. turn the target runtime gate on;
3. run a warm seed copy while the source is still live;
4. turn the source runtime gate on;
5. run the final copy;
6. deploy the normal target generation;
7. turn the target runtime gate off;
8. leave the source drained unless `--resume-source` is passed.

`--warm` only runs the seed copy. It does not bootstrap the target and does not
toggle either migration-manager gate.

`--skip-deploy` means the tool will not run the target bootstrap deploy and will
not call `migration-manager`. Use it only when the source and target are already
in the desired drain state.

## Existing Target Host

Use this when the destination host already exists in the repo and nixbot
inventory, and you want the tool to drain it, copy data, and resume it.

Seed only:

```bash
nix run .#data-migrator -- \
  --profile abird-corp \
  --source-host OLD_COPY_SSH_HOST \
  --target-host TARGET_NIXBOT_HOST \
  --warm
```

Full live cutover:

```bash
nix run .#data-migrator -- \
  --profile abird-corp \
  --source-host OLD_COPY_SSH_HOST \
  --source-drain-host OLD_NIXBOT_HOST \
  --target-host TARGET_NIXBOT_HOST \
  --target-drain-host TARGET_NIXBOT_HOST
```

Use `--resume-source` only for a deliberate rollback or dual-run window. The
default is safer for cutover: target resumes, source stays drained, and there is
no accidental split-brain writer.

If the target is already bootstrapped and you have manually put both hosts in
the right state, run only the copy logic:

```bash
nix run .#data-migrator -- \
  --profile abird-corp \
  --source-host OLD_COPY_SSH_HOST \
  --target-host TARGET_NIXBOT_HOST \
  --source-drain-host OLD_NIXBOT_HOST \
  --target-drain-host TARGET_NIXBOT_HOST \
  --skip-deploy
```

## New Target Host

Use this when the destination host is newly declared but should receive the same
profile data.

Prerequisites:

- the new host exists in the repo;
- the new host exists in `hosts/nixbot.nix`;
- secrets, users, data directories, and service declarations needed by the
  target generation are in place;
- the host can be deployed by nixbot from this repo.

Run a seed first when the data set is large:

```bash
nix run .#data-migrator -- \
  --profile abird-corp \
  --source-host OLD_COPY_SSH_HOST \
  --target-host NEW_NIXBOT_HOST \
  --warm
```

Run the full cutover:

```bash
nix run .#data-migrator -- \
  --profile abird-corp \
  --source-host OLD_COPY_SSH_HOST \
  --source-drain-host OLD_NIXBOT_HOST \
  --target-host NEW_NIXBOT_HOST \
  --target-drain-host NEW_NIXBOT_HOST
```

The target bootstrap deploy uses a temporary worktree under `tmp/`, writes a
private migration-manager bootstrap override for the target host, deploys that
drained generation, and removes the temporary worktree after a successful
deploy. If the bootstrap deploy fails, the worktree is kept for inspection.

## Incus Migrations

Incus mode is enabled by `--source-project`, `--target-project`,
`--source-instance`, `--incus-instance`, or `--target-instance`.

For Abird profiles, Incus commands run on the delegated controller `abird-nest`
by default. The profile name is also the default source instance name.

Move or refresh an instance into another project:

```bash
nix run .#data-migrator -- \
  --profile abird-corp \
  --source-project abird \
  --target-project abird-stage
```

Move to a new target instance name:

```bash
nix run .#data-migrator -- \
  --profile abird-corp \
  --source-project abird \
  --target-project abird-stage \
  --target-instance abird-corp-next
```

Refresh an existing target only when it was previously created or refreshed from
the same source markers. If the target already exists and does not have matching
`user.data-migrator.*` markers, the tool refuses to refresh it. Override that
only after verifying the target is safe to overwrite:

```bash
nix run .#data-migrator -- \
  --profile abird-corp \
  --source-project abird \
  --target-project abird-stage \
  --force-refresh-existing
```

The native Incus fast path is used when source and target are on the same Incus
remote and the root disk is on the same btrfs pool. Otherwise the tool falls
back to file copies and needs `--target-host` or `--target-dir`.

During a full Incus migration the tool creates a live seed snapshot, copies or
refreshes the target, drains source and target services, stops the source
instance, stops the target instance if it exists, creates a final snapshot,
refreshes the target, starts the target unless disabled, and removes temporary
snapshots.

## Cutover Checklist

Before the final copy:

- confirm the source host has a deployed generation with `migration-manager`;
- confirm the target host can be deployed by nixbot;
- confirm the profile paths in `pkgs/tools/data-migrator/profiles.nix` include
  the state that must move and exclude volatile cache paths;
- run a warm seed for large data sets;
- check there is enough disk space on the target;
- decide whether the source should remain drained, be resumed, or be stopped
  after cutover;
- decide whether Incus should start the target automatically or use
  `--no-start-target --no-resume-target`.

During the cutover:

- do not resume source writers while target services are accepting writes;
- treat `--skip-deploy` as an expert mode, not a convenience flag;
- keep the failed bootstrap worktree if a target bootstrap deploy fails;
- prefer `--dry-run` or `--nixbot-dry` when validating command shape, but do not
  mistake them for data-copy verification.

After the cutover:

```bash
nix run .#migration-manager -- remote status --host TARGET_NIXBOT_HOST
```

Expected target status after a normal successful cutover is `off`.

Check migration-manager units:

```bash
ssh TARGET_NIXBOT_HOST 'sudo systemctl status migration-manager-sync.service migration-manager-apply.service'
```

Check for failed system units:

```bash
ssh TARGET_NIXBOT_HOST 'sudo systemctl --failed'
```

Check native user units and targets:

```bash
ssh TARGET_NIXBOT_HOST 'uid=$(id -u abird); sudo -u abird XDG_RUNTIME_DIR=/run/user/$uid DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus systemctl --user status abird-managed.target'
```

For Incus migrations, check instance placement and state from the controller:

```bash
ssh abird-nest 'incus list --project TARGET_PROJECT'
ssh abird-nest 'incus info --project TARGET_PROJECT TARGET_INSTANCE'
```

Then verify service-specific health:

- inspect application logs for startup errors;
- verify databases or stateful services opened their migrated data cleanly;
- verify public routes and internal routes for the moved services;
- verify auth callbacks and external-provider integrations still point at the
  intended host or service URL;
- verify background workers are not duplicated on source and target;
- keep the source drained until target health and data correctness are accepted.

If rollback is needed, keep the target drained or stopped before resuming the
source:

```bash
nix run .#migration-manager -- remote on --host TARGET_NIXBOT_HOST
nix run .#migration-manager -- remote off --host OLD_NIXBOT_HOST
```

Only resume both source and target intentionally when the service is known to
support active-active writes.
