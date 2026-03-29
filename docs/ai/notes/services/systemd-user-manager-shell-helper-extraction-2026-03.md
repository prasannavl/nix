# systemd-user-manager Shell Helper Extraction (2026-03)

## Context

`lib/systemd-user-manager.nix` had grown large embedded shell strings for three
separate execution paths:

- the user reconciler
- the root dispatcher
- the activation-time stop and dry-preview flow

That made the shell harder to lint and review, and every behavior change had to
be edited inside Nix string literals.

## Decision

- Move the module body to `lib/systemd-user-manager/default.nix`.
- Extract the shared Bash into `lib/systemd-user-manager/helper.sh`.
- Build the helper with `pkgs.replaceVars` so the checked-in shell file keeps
  stable placeholders for Nix-provided tool paths and constants.
- Pass per-user and per-generation data through explicit environment variables
  like `SYSTEMD_USER_MANAGER_USER`, `SYSTEMD_USER_MANAGER_UID`,
  `SYSTEMD_USER_MANAGER_METADATA`, and the activation preview manifest path.

## Outcome

- The systemd services and activation snippet now call the same helper with
  subcommands:
  - `reconciler-apply`
  - `dispatcher-start`
  - `activation-run`
- The Nix module owns data modeling and service wiring.
- The shell helper owns control flow and can be shellchecked after Nix
  substitution.

## Regressions Found And Fixed

- Restored the dispatcher metadata pointer files under
  `/etc/systemd-user-manager/dispatchers/*.metadata`; without them, activation
  old/new manifest diffing could miss managed-unit changes.
- Captured the resolved old generation path at activation start instead of
  relying on the mutable `/run/current-system` symlink inside the helper.
- Fixed `nixbot` deploy-summary streaming to follow the reconciler's new
  `InvocationID` instead of caching a stale previous run, which could hide real
  start logs after activation had already stopped changed units.
- Fixed the `nixbot` fallback path so it does not discard dispatcher-carried
  reconciler replay lines before the reconciler `InvocationID` becomes
  discoverable; when no current reconciler invocation can be attached yet, the
  summary now streams the raw dispatcher journal instead of a dispatcher-only
  grep.

## Follow-Up

- Keep future shell behavior changes in `helper.sh` unless they require new Nix
  metadata or service wiring.
- If the environment contract changes, update both the helper and the Nix
  service `Environment=` definitions in the same change.
