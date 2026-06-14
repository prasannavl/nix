# Incus Readiness

This document covers the deploy-time readiness barrier for Incus guests.

## Goal

Before `nixbot` deploys into an Incus guest, the parent host must confirm that
the guest is:

- running
- reachable through `incus exec`
- on the expected IPv4 address
- accepting SSH when SSH is expected

## Parent-Host Helpers

Installed on parent hosts that declare
`services.incus-manager.<project>.instances`:

- `incus-machines-reconciler`
- `incus-machines-settlement`

## `incus-machines-reconciler`

Ensures selected non-ignored guests match their declared `state`.

Typical usage:

```sh
incus-machines-reconciler --all
incus-machines-reconciler --machine llmug-rivendell
```

Batch failure behavior is controlled by
`services.incus-manager.global.reconcileFailurePolicy`:

- `best-effort`
- `strict`

`strict` means failed attempted reconcile actions abort the batch. It does not
make `declarative` pending recreate drift fail, and ignored instances are
outside the batch reconcile contract.

Per-instance lifecycle mutation is controlled by
`services.incus-manager.<project>.instances.<name>.reconcilePolicy`:

- `auto`
- `declarative`
- `ignore`

Use `state = "running" | "stopped"` for desired runtime state and `autoStart`
for whether the `incus-<name>.service` is wanted at boot or target startup.
`autoStart` is independent of `reconcilePolicy`. Ignored instances keep that
systemd control surface; start only starts an existing guest, and declarative
create/recreate/stop/drift reconcile is skipped.

For `reconcilePolicy = "ignore"`, `autoStart = true` still enables the
`incus-<name>.service` even when `state = "stopped"`. That unit start uses the
narrow existing-guest start path, so set `autoStart = false` if the ignored
guest should stay stopped.

## `incus-machines-settlement`

Waits until selected guests pass readiness checks:

1. instance status is `Running`
2. `incus exec <name> -- true` works
3. the expected IPv4 address is present
4. SSH is reachable when `waitForSsh = true`

Typical usage:

```sh
incus-machines-settlement --all
incus-machines-settlement --timeout 120
incus-machines-settlement --track-ignored --all
incus-machines-settlement --timeout 120 --machine llmug-rivendell
```

Broad settlement (`--all`, or no explicit selector) skips instances with
`reconcilePolicy = "ignore"` unless `--track-ignored` is set. Explicit
settlement with `--machine` or `--instance` still checks ignored instances, so a
deploy target can be opted out of mutation while remaining an explicit readiness
dependency.

Per-guest settings that affect settlement:

- `ipv4Address`
- `sshPort`
- `waitForSsh`

## `nixbot` Deploy Barrier

Before each deploy wave, `nixbot` checks hosts that declare a `parent` in
`hosts/nixbot.nix`.

For each parent group it:

1. runs reconcile on the parent
2. runs settle on the parent
3. deploys only if both succeed

If either step fails, the deploy wave fails.

`nixbot` passes explicit `--machine <name>` arguments for the children in the
current deploy wave. That means ignored siblings are not checked by default, but
an ignored child that is actually being deployed must still be ready.

## Failure Behavior

If parent readiness fails:

- hosts in that deploy wave are marked failed
- earlier successfully deployed hosts in the run are rolled back
- unrelated hosts outside that readiness group are unaffected

## Further Reading

- [`docs/incus-vms.md`](./incus-vms.md)
- [`docs/deployment.md`](./deployment.md)

## Detailed Reference

The sections below cover orchestration details, batching behavior, and related
runtime mechanics.

## Overview

This readiness layer exists because a declared Incus guest may still be
undeployed, starting, or not yet reachable when `nixbot` reaches its deploy
wave. The parent-host reconcile and settle steps close that gap before the child
host switch begins.

## Nixbot Deploy-Time Readiness Barrier

### When it runs

Before each **deploy wave**, `nixbot` runs parent readiness checks for every
host in that wave that has a `parent` declared in `hosts/nixbot.nix`. A deploy
wave is a group of hosts at the same topological level that can be deployed in
parallel.

For example, given:

```nix
{
  hosts = {
    pvl-x2 = { target = "pvl-x2"; };
    llmug-rivendell = {
      target = "10.10.20.10";
      parent = "pvl-x2";
    };
    gap3-gondor = {
      target = "10.10.20.11";
      parent = "pvl-x2";
      after = ["llmug-rivendell"];
    };
  };
}
```

When deploying `llmug-rivendell`, `nixbot` SSHes to `pvl-x2` and runs
reconcile + settle for `llmug-rivendell` before deploying into it.

Ignored guests are skipped by broad settlement (`--all` or no selector) unless
`--track-ignored` is set, but explicit `--machine` selection still requires
readiness. This keeps manual lifecycle opt-outs quiet during catch-all checks
while preserving deploy safety for hosts selected by the current wave.

### Command templates

The reconcile and settle commands are rendered from templates that support these
placeholders:

- `{resourceArgs}` -- expands to `--machine <name>` flags for all machines in
  the batch.
- `{resource}` -- expands to a single machine name (used when batching is not
  possible).
- `{timeout}` -- expands to the settle timeout value.

Templates that contain `{resourceArgs}` (and not `{resource}`) support batching
multiple machines into a single command. Otherwise, machines are handled one at
a time.

## Nixbot SSH Readiness Cache

Separately from the Incus container readiness checks, `nixbot` caches SSH
connectivity state per node within a single deploy run:

- **Bootstrap readiness** (`bootstrap-ready.nodes`) -- records nodes where the
  bootstrap SSH path has been validated. Prevents redundant bootstrap key checks
  across the snapshot and deploy phases.
- **Primary readiness** (`primary-ready.nodes`) -- records nodes where the
  primary `nixbot@<host>` SSH path is confirmed working. Prevents redundant
  connectivity probing when the same host is touched multiple times in a run.

These caches are per-run only (stored in `$NIXBOT_TMP_DIR`) and do not persist
between runs.

## Optional Boot-Time Reconcile

Parent hosts can optionally run `incus-machines-reconciler --all` at boot via
the `incus-machines-reconciler.service` systemd unit:

```nix
services.incus-manager.global.autoReconcile = true;
```

This is **disabled by default** so that host boot does not block on guest
convergence. When enabled, it runs after `incus-preseed.service`,
`incus-images.service`, and `incus-machines-gc.service`.

Even without `autoReconcile`, each declared guest has its own
`incus-<name>.service`. `autoStart` controls whether that unit is wanted at
boot, including for ignored guests. The reconcile service is an additional
catch-all for non-ignored guests that drift away from their desired `state`. For
ignored guests, an enabled lifecycle unit starts the existing guest even if the
declaration says `state = "stopped"`.

## Lifecycle Summary

```text
Parent host activation (NixOS rebuild):
  incus-preseed.service
  incus-images.service        (import/refresh declared images)
  incus-machines-gc.service   (remove undeclared containers)
  incus-<name>.service        (create/start/stop according to state and policy)
  incus-machines-reconciler   (optional: reconcile non-ignored state drift)

nixbot deploy wave for child hosts:
  ensure_deploy_wave_parent_readiness:
    SSH to parent -> incus-machines-reconciler --machine <children>
    SSH to parent -> incus-machines-settlement --timeout T --machine <children>
      explicitly selected ignored children are checked; ignored siblings are not
      polls until:
        container status == Running
        incus exec succeeds
        expected IPv4 present
        SSH port reachable (if waitForSsh)
  deploy:
    SSH to child -> nixos-rebuild switch
```

## Source Of Truth Files

- `lib/incus/default.nix` and `lib/incus/helper.sh` -- reconciler helper, settle
  helper, per-machine service, machine type options (`sshPort`, `waitForSsh`,
  `ipv4Address`)
- `pkgs/tools/nixbot/nixbot.sh` -- `ensure_deploy_wave_parent_readiness`,
  `run_named_prepared_root_command`, command template rendering
- `hosts/nixbot.nix` -- `parent`, `after`, and deploy target definitions

## Related Docs

- `docs/incus-vms.md`: Incus guest lifecycle model (images, tags, devices, GC).
- `docs/deployment.md`: Deploy architecture, bootstrap flow, and secret model.
