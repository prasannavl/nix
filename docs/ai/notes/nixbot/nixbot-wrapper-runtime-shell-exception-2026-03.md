# Nixbot Wrapper Runtime Shell Exception 2026-03

## Context

- `scripts/nixbot.sh` is only a thin pass-through wrapper to
  `pkgs/nixbot/nixbot.sh`.
- The delegated `pkgs/nixbot/nixbot.sh` entrypoint already owns the runtime
  dependency setup and `nix shell` re-exec behavior.

## Decision

- Removed the redundant `ensure_runtime_shell` wrapper from `scripts/nixbot.sh`.
- Kept `scripts/nixbot.sh` as a minimal handoff that resolves the target path
  and `exec`s into the real entrypoint.
- Added a Bash-pattern exception allowing thin wrapper scripts to skip
  `ensure_runtime_shell` when the delegated entrypoint already handles runtime
  setup.

## Result

- `scripts/nixbot.sh` stays simple and avoids duplicated runtime bootstrapping.
- The Bash rule remains explicit without forcing redundant wrapper behavior.
