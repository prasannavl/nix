# Nixbot Runtime Workspace Consolidation (2026-03)

## Scope

Consolidate `scripts/nixbot.sh` runtime temp allocation into one per-run
workspace root that holds both the detached repo worktree and runtime artifacts.

## Decision

- Allocate one workspace root per run:
  - `/dev/shm/nixbot-run.XXXXXX` when shared memory is available
  - `${TMPDIR:-/tmp}/nixbot-run.XXXXXX` otherwise
- Use that directory as the base for both:
  - detached repo worktree at `.../repo`
  - deploy logs, statuses, artifacts, SSH temp files, and decrypted runtime
    secrets under sibling paths in the same root
- Re-exec into the worktree copy of the script must inherit the same workspace
  root through `NIXBOT_RUNTIME_WORK_DIR` so the run does not allocate a second
  temp tree.

## Rationale

- One top-level temp allocation is simpler to reason about and to clean up.
- The worktree and runtime outputs become inherently correlated because they
  share one parent directory instead of depending on matching names.
- The model removes the need for a second temp-dir naming scheme entirely.
