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

Installed on parent hosts that declare `services.incusMachines.instances`:

- `incus-machines-reconciler`
- `incus-machines-settlement`

## `incus-machines-reconciler`

Ensures declared guests are running.

Typical usage:

```sh
incus-machines-reconciler --all
incus-machines-reconciler --machine <guest-a> --machine <guest-b>
```

Policy is controlled by `services.incusMachines.reconcilePolicy`:

- `off`
- `best-effort`
- `strict`

## `incus-machines-settlement`

Waits until selected guests pass readiness checks:

1. instance status is `Running`
2. `incus exec <name> -- true` works
3. the expected IPv4 address is present
4. SSH is reachable when `waitForSsh = true`

Typical usage:

```sh
incus-machines-settlement --all
incus-machines-settlement --machine <guest-a> --timeout 120
```

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

## Failure Behavior

If parent readiness fails:

- hosts in that deploy wave are marked failed
- earlier successfully deployed hosts in the run are rolled back
- unrelated hosts outside that readiness group are unaffected

## Quick Links

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
    <parent-host> = { target = "<parent-host>"; };
    <guest-a> = {
      target = "<guest-a-ip>";
      parent = "<parent-host>";
    };
    <guest-b> = {
      target = "<guest-b-ip>";
      parent = "<parent-host>";
      after = ["<guest-a>"];
    };
  };
}
```

When deploying `<guest-a>`, `nixbot` SSHes to `<parent-host>` and runs
reconcile + settle for `<guest-a>` before deploying into it.

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
services.incusMachines.autoReconcile = true;
```

This is **disabled by default** so that host boot does not block on guest
convergence. When enabled, it runs after `incus-preseed.service`,
`incus-images.service`, and `incus-machines-gc.service`.

Even without `autoReconcile`, each declared guest has its own
`incus-<name>.service` that runs at boot. The reconcile service is an additional
catch-all that restarts any guest that failed to start or was stopped
externally.

## Lifecycle Summary

```text
Parent host activation (NixOS rebuild):
  incus-preseed.service
  incus-images.service        (import/refresh declared images)
  incus-machines-gc.service   (remove undeclared containers)
  incus-<name>.service        (create/start each declared container)
  incus-machines-reconciler   (optional: restart any that aren't Running)

nixbot deploy wave for child hosts:
  ensure_deploy_wave_parent_readiness:
    SSH to parent -> incus-machines-reconciler --machine <children>
    SSH to parent -> incus-machines-settlement --timeout T --machine <children>
      polls until:
        container status == Running
        incus exec succeeds
        expected IPv4 present
        SSH port reachable (if waitForSsh)
  deploy:
    SSH to child -> nixos-rebuild switch
```

## Source Of Truth Files

- `lib/incus/default.nix` -- reconciler helper, settle helper, per-machine
  service, machine type options (`sshPort`, `waitForSsh`, `ipv4Address`)
- `pkgs/tools/nixbot/nixbot.sh` -- `ensure_deploy_wave_parent_readiness`,
  `run_named_prepared_root_command`, command template rendering
- `hosts/nixbot.nix` -- `parent`, `after`, and deploy target definitions

## Further Reading

- `docs/incus-vms.md`: Incus guest lifecycle model (images, tags, devices, GC).
- `docs/deployment.md`: Deploy architecture, bootstrap flow, and secret model.
