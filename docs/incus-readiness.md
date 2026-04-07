# Incus Guest Readiness And Deploy Barriers

This document describes the readiness lifecycle that bridges Incus guest
container management on parent hosts with `nixbot` deploy orchestration. It
explains what each readiness check does, when it runs, and what happens on
failure.

For the Incus guest lifecycle model (images, tags, devices, GC), see
`docs/incus-vms.md`. For the `nixbot` deploy architecture and bootstrap flow,
see `docs/deployment.md`.

## Overview

When `nixbot` deploys a child host that runs inside an Incus container on a
parent host, it cannot just SSH in and run `nixos-rebuild`. The container must
be running, its network must be up, and its SSH daemon must be accepting
connections. Two host-side helpers and a `nixbot` orchestration barrier ensure
this.

The flow for each deploy wave is:

1. **Reconcile** -- ensure the container is running on the parent.
2. **Settle** -- wait until the container is fully reachable.
3. **Deploy** -- SSH into the container and switch its NixOS configuration.

If either reconcile or settle fails, the entire wave is aborted and affected
hosts are marked as failed.

## Host-Side Helpers

Both helpers are installed on every parent host that declares
`services.incusMachines.instances` in its NixOS configuration. They live in
`lib/incus/default.nix` and are available as executables on the parent's
`$PATH`.

### `incus-machines-reconciler`

Ensures declared containers are running. For each selected machine:

1. Queries `/1.0/instances/<name>` to get the container status.
2. If the container is already `Running`, skips it.
3. If the container is stopped, missing, or in any other state, runs
   `systemctl restart incus-<name>.service` to bring it back through the full
   per-machine lifecycle service (create from image if missing, start if
   stopped).

Behavior is governed by `services.incusMachines.reconcilePolicy`:

- `off` -- reconcile helpers are not installed.
- `best-effort` (default) -- log failures and continue to the next machine.
- `strict` -- fail immediately on any machine that cannot be reconciled.

Usage:

```bash
incus-machines-reconciler --all
incus-machines-reconciler --machine pvl-vlab --machine gap3-gondor
```

### `incus-machines-settlement`

Polls until all selected containers pass four readiness checks, or until a
timeout is reached (default 180 seconds, polling every 2 seconds):

1. **Container status is `Running`** -- queries the Incus instance API.
2. **`incus exec` works** -- runs `incus exec <name> -- true` with a 10-second
   timeout to verify the container agent is responsive.
3. **Expected IPv4 is present** -- queries the instance state API and checks
   that the declared `ipv4Address` appears on a non-loopback interface inside
   the container.
4. **SSH is reachable** (if `waitForSsh = true`) -- opens a TCP connection to
   `<ipv4Address>:<sshPort>` with a 5-second timeout.

Each check must pass for a machine to be considered settled. The poll loop runs
all machines on each iteration; only when every machine passes all checks does
settle succeed.

Usage:

```bash
incus-machines-settlement --all
incus-machines-settlement --machine pvl-vlab --timeout 120
```

Per-machine options that affect settle behavior:

- `sshPort` (default `22`) -- the TCP port checked for SSH reachability.
- `waitForSsh` (default `true`) -- set to `false` for containers that
  intentionally do not run SSH.
- `ipv4Address` -- the expected address checked in the instance state.

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
    pvl-vlab = {
      target = "10.10.20.10";
      parent = "pvl-x2";
    };
    gap3-gondor = {
      target = "10.10.20.11";
      parent = "pvl-x2";
      after = ["pvl-vlab"];
    };
  };
}
```

When deploying `pvl-vlab`, `nixbot` SSHes to `pvl-x2` and runs reconcile +
settle for `pvl-vlab` before deploying into it.

### What it does

The function `ensure_deploy_wave_parent_readiness` in `nixbot.sh`:

1. **Groups hosts by parent** -- hosts sharing the same parent and the same
   reconcile/settle command templates are batched together so the parent is only
   contacted once per group.

2. **Runs reconcile on the parent** -- SSHes to the parent host and executes the
   reconcile command template. The default template is:

   ```bash
   /run/current-system/sw/bin/incus-machines-reconciler --machine <name> [--machine <name2> ...]
   ```

   This ensures any stopped or missing containers are restarted before settle.

3. **Runs settle on the parent** -- SSHes to the parent host and executes the
   settle command template. The default template is:

   ```bash
   /run/current-system/sw/bin/incus-machines-settlement --timeout <timeout> --machine <name> [--machine <name2> ...]
   ```

   This blocks until all containers in the group pass the four readiness checks
   (status, exec, IP, SSH).

4. **Reports success or failure** -- if either phase fails, the entire deploy
   wave is aborted and all hosts in the wave are marked as failed.

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

### Failure behavior

If parent readiness fails for any group in a wave:

1. All hosts in the wave are marked as failed.
2. Any hosts that were successfully deployed earlier in the run are rolled back.
3. The deploy phase returns a failure exit status.

This means a container that refuses to start or settle will block its own deploy
and trigger rollback of previously deployed hosts in the same run, but will not
prevent unrelated hosts (those without a parent, or with a different parent)
from being deployed.

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

## Related Docs

- `docs/incus-vms.md`: Incus guest lifecycle model (images, tags, devices, GC).
- `docs/deployment.md`: Deploy architecture, bootstrap flow, and secret model.
