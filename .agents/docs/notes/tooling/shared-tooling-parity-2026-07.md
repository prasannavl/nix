# Shared Tooling Parity 2026-07

## Scope

This parity pass reconciles the generic Podman, nixbot, and host-manager seams
between Abird and the Pvl Nix repository. Shared implementation and tests stay
byte-identical; repository policy remains in repository-owned stack and host
configuration.

## Ownership Boundary

- `lib/podman-compose/default.nix` reapplies the service submodule after a
  function-valued instance is invoked, so nested option defaults are preserved.
- `pkgs/tools/nixbot` uses a persistent mode-`0755` host-local lock directory.
  Lock users open the directory read-only and never unlink it, preserving one
  inode across principals, waiters, normal release, and error cleanup.
- `pkgs/tools/host-manager/host-manager.sh` owns only generic mechanics.
- `pkgs/tools/host-manager/policy.nix` owns the repository's default service
  stack, deployment-host mapping, and generated-host module imports, following
  the package-owned policy pattern used by data-migrator's `profiles.nix`.
- Existing stack data provides `srv.defaultUser`; host-manager derives the
  fallback unit prefix from it.
- Generated Incus hosts use `machineProfiles.incusLxc`; ordinary generated hosts
  use `machineProfiles.vm`.

## Parity Contract

The shared Podman files, nixbot shell/test files, host-manager implementation,
and host-manager tests must be byte-identical across the two worktrees. The
host-manager refactor does not require changes to the stack library, service
registry, shared flake tests, or repository stack definitions. Only the
repository-owned `pkgs/tools/host-manager/policy.nix` intentionally differs.

## Validation

- The direct host-manager and nixbot suites passed all 30 and 161 tests,
  respectively.
- Sandboxed host-manager and nixbot package tests, the Podman module check, and
  isolated flake evaluation passed in both repositories.
- Representative policy mappings evaluated to each repository's intended
  inventory hosts.
- Abird production/stage and Pvl physical/AI NixOS toplevel builds passed.
- The final common-file audit found 310 byte-identical files and 21 explained,
  repo-owned differences under `lib/**` and `pkgs/**`. The additional package
  difference is host-manager's repository policy; there is no unexplained
  shared-file divergence.
