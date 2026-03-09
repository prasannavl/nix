# Nixbot Deploy Flow Consolidated Notes (2026-03)

## Scope

Consolidates the March 2026 deploy-script changes that were previously tracked
as separate notes for bastion triggering, same-user bootstrap caching, and
remote-build preflight behavior.

## Final state

- `scripts/nixbot-deploy.sh` now has a built-in bastion trigger mode via
  `--bastion-trigger`, so workflows and operators can use one script for both
  local deploy orchestration and bastion-side trigger execution.
- Trigger inputs follow normal deploy option/env precedence:
  argument override, then environment, then built-in defaults.
- Host normalization for bastion-trigger mode matches the main deploy path.
- When the deploy user and bootstrap user are the same, bootstrap key injection
  is cached per host within a run so snapshot and deploy phases do not repeat
  the same install work or sudo prompt.
- Remote-build deploy preflight no longer performs an eager local realisation.
  If `DEPLOY_BUILD_HOST` is non-local, preflight records the expected
  `toplevel.outPath` with `nix eval` and leaves the actual build to
  `nixos-rebuild --build-host`.

## Why this matters

- Bastion triggering is now part of the normal deploy surface instead of a
  parallel wrapper path.
- Same-user bootstrap flows are quieter and idempotent within one run.
- Remote-build deploys now behave like actual remote builds instead of
  accidentally building locally first.

## Canonical interpretation

Treat this file as the canonical summary for the following superseded
March 2026 notes:

- `nixbot-local-bastion-trigger-script-2026-03-03.md`
- `nixbot-bootstrap-ready-cache-same-user-2026-03-07.md`
- `nixbot-remote-build-preflight-outpath-2026-03-07.md`
