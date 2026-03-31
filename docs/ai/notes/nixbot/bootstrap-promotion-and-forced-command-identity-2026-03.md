# Nixbot Bootstrap Promotion And Forced-Command Identity

## Context

Nested-host deploys could fall through this sequence:

1. primary `nixbot@host` probe failed
2. bootstrap check failed
3. bootstrap key injection via `bootstrapUser` succeeded
4. deploy still kept `--target-host` on `bootstrapUser@host`

With `BUILD_HOST=local`, that made `nixos-rebuild-ng` copy the already-built
closure to `ssh://bootstrapUser@host`, which fails because the bootstrap user is
not a trusted Nix store importer.

Separately, the bootstrap probe stripped the prepared `-i` / `IdentitiesOnly`
arguments even when no dedicated forced-command key override was configured, so
the probe could fail only because it had lost the correct identity.

## Root Cause

- `prepare_deploy_context()` treated bootstrap injection as sufficient reason to
  keep the prepared deploy context on the bootstrap user.
- It did not re-probe `nixbot@host` after bootstrap key preparation.
- `check_bootstrap_via_forced_command()` always removed the prepared SSH
  identity, then only added a replacement when
  `NIXBOT_BASTION_KEY_PATH_OVERRIDE` was set.

## Decision

- Bootstrap checks must preserve the prepared deploy identity by default and
  only replace it when an explicit override key is configured.
- After cached or fresh bootstrap key preparation, `prepare_deploy_context()`
  must clear the primary control socket, re-probe the primary deploy target, and
  promote back to `nixbot@host` when that route is restored.
- Bootstrap probes should also clear the failed primary control socket first so
  the check does not inherit a broken SSH master session.
- If a local-build deploy still ends up on a non-`root`, non-`nixbot` bootstrap
  user, fail early with an explicit error instead of letting `nix-copy-closure`
  fail with a remote trust error.

## Operational Effect

- bootstrap key preparation can repair the primary deploy path within the same
  run
- local-build deploys no longer silently continue on `pvl@host` after bootstrap
  injection
- bootstrap probes no longer fail just because the correct SSH identity was
  discarded
