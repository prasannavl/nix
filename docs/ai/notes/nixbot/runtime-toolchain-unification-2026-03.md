# Nixbot Runtime Toolchain Unification 2026-03

## Summary

Unified `scripts/nixbot-deploy.sh` runtime dependency declaration and
verification so the runtime shell installables and expected commands are
declared once and reused everywhere.

## What Changed

- Added one shared list of runtime Nix installables.
- Added one shared list of commands expected to exist after entering that
  runtime shell.
- Reused those shared lists for:
  - `ensure_runtime_shell`
  - `--ensure-deps`
  - normal runtime verification before deploy logic runs
- Removed redundant `require_cmds` calls from the TF, deploy-config, and host
  action paths.

## Operational Notes

- `scripts/nixbot-deploy.sh --ensure-deps` now exercises the same runtime
  contract the real deploy path depends on.
- The runtime shell still provides the same tools as before; this change only
  centralizes the contract so future edits do not drift.
