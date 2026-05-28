# Data Migrator And Incus Drain, 2026-05

## Scope

This note records the local selective port of the post-`8314da5b` gap3
data-migrator and migration-drain commits.

## Ported

- Added a generic `pkgs/tools/data-migrator` package and root package/app
  export.
- Kept the file-copy and Incus-copy mechanics:
  - rsync with streamed aggregate progress
  - Nix-provided source-side rsync default
  - tar fallback
  - guarded Incus native copy/refresh with `user.data-migrator.*` source markers
  - controller-host wrapping for Incus client commands
- Added `services.incusMachines.<project>.instances.<name>.drain`.
  - `drain = true` stops an existing managed Incus container.
  - It suppresses missing-instance cold-starts while the flag remains true.
  - Auto-reconcile skips stopped drained instances and re-runs the lifecycle
    unit only when a drained instance is still running.

## Skipped Or Deferred

- Abird-specific data-migrator profiles, host names, paths, and examples were
  not ported.
- The upstream `x.migrator.on` host-wide hold was not ported. It affected
  ordinary hosts, package-backed services, Podman stacks, cloudflared, and
  managed user services; local scope is intentionally limited to repo-managed
  Incus LXCs.
- `data-migrator` does not patch Nix config or deploy drain/resume states. Set
  `services.incusMachines.<project>.instances.<name>.drain = true` in the parent
  host configuration and deploy that parent when app-consistent LXC migration
  state is required.
