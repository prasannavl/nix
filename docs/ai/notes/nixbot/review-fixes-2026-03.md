# Nixbot Review Fixes (2026-03)

## Scope

Follow-up fixes for the March 2026 `pkgs/nixbot/nixbot.sh` review covering
forced-command bootstrap validation, Terraform-only dispatch, and managed repo
locking.

## Changes

### Forced-command bootstrap checks stay repo-local on the remote host

- `check_bootstrap_via_forced_command` no longer forwards the caller's local
  `HEAD` SHA for the remote probe.
- If the operator explicitly requested `--sha`, the bootstrap probe forwards
  that same SHA so validation uses the same revision the deploy run requested.
- Relative `--config` paths stay relative when forwarded so the remote host
  resolves them inside its own repo worktree instead of against the caller's
  local absolute worktree path.
- Absolute config paths are forwarded only when they can be mapped back to a
  repo-relative path under the current repo root or deploy worktree; otherwise
  the forced-command probe fails closed and falls back instead of validating the
  wrong config.
- Deploy config loading now fails cleanly when `NIXBOT_CONFIG_PATH` is set but
  the file is missing; it no longer silently skips config initialization and
  falls back to defaults.
- This keeps the bootstrap probe aligned with the requested deploy revision and
  repo-local config while avoiding false success from a missing remote config or
  false failure from an implicit unpushed local commit.

### Terraform-only actions bypass host orchestration setup

- `tf`, `tf-dns`, `tf-platform`, `tf-apps`, and `tf/<project>` should not load
  deploy host metadata or validate selected hosts before dispatch.
- TF-only actions now log the action header directly and go straight to the
  Terraform flow.
- Host/config failures should no longer block pure Terraform runs.

### Managed repo locking covers first clone too

- The repo-root lock now falls back to a lock path adjacent to `REPO_ROOT` when
  no git dir exists yet.
- This serializes the initial clone/bootstrap path instead of only locking after
  the managed mirror already exists.
