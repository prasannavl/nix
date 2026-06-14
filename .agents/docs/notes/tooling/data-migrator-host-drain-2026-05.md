# Data Migrator And Host Drain, 2026-05

## Scope

This note records the local selective port of the post-`8314da5b` gap3
data-migrator and migration-drain commits.

## Ported

- Added the generic `pkgs/tools/data-migrator` package and root package/app
  export.
- Kept the file-copy and Incus-copy mechanics:
  - rsync with streamed aggregate progress
  - Nix-provided source-side rsync default
  - tar fallback
  - guarded Incus native copy/refresh with `user.data-migrator.*` source markers
  - controller-host wrapping for Incus client commands
- Ported the gap3 generation-owned host drain design instead of the earlier
  local Incus-container stop drain.
  - `data-migrator` used to patch host modules in temporary worktrees and deploy
    them through `nixbot`.
  - `lib/flake/service-module.nix` actively stops package-backed services and
    suppresses their normal `wantedBy` attachments while drain is on.
  - `lib/podman-compose/default.nix` suppresses compose auto-start during drain.
  - `lib/systemd-user-manager/default.nix` drains managed user units.
  - `lib/services/tunnels/cloudflare.nix` suppresses host-managed Cloudflare
    tunnels during drain.

## Removed

- Removed the local `services.incus-manager.<project>.instances.<name>.drain`
  invention. It stopped the whole Incus container from the parent host, which is
  not the desired semantics for NixOS hosts that are themselves Incus LXCs.
- `lib/incus/default.nix` and `lib/incus/helper.sh` are back to the upstream
  gap3 shape for the common files.

## Deferred

- Abird-specific data-migrator profiles, host names, paths, and examples remain
  project-specific to gap3 unless a matching local service stack is explicitly
  requested.
