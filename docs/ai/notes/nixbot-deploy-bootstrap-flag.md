# Nixbot Deploy: `--bootstrap` Force-Bootstrap Path Option

## Context

- Request: add a CLI option to `scripts/nixbot-deploy.sh` to always force
  bootstrap path selection.

## Changes

- Added `--bootstrap` option to CLI usage/help output.
- Added `FORCE_BOOTSTRAP_PATH` runtime flag and argument parsing.
- In `prepare_deploy_context`, when `--bootstrap` is set:
  - always select `${bootstrap_user}@${host}` as deploy SSH target.
  - set deploy SSH options/NIX_SSHOPTS from bootstrap settings.
  - mark context as using bootstrap fallback.
  - inject bootstrap key (when configured) before returning.
- Updated `docs/deployment.md` to document `--bootstrap` behavior.

## Result

- Deploy/snapshot/rollback SSH target selection can be forced to bootstrap path
  regardless of primary target reachability.

## Follow-up Clarification

- Bootstrap remains automatic on normal deploy path (primary probe ->
  forced-command check -> bootstrap injection fallback).
- `--bootstrap` is an explicit force override, not the only way to bootstrap.
