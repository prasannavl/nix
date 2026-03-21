# Nixbot dirty repo bypass flag - 2026-03

- `nixbot` now supports `--dirty` plus `NIXBOT_DIRTY=1` to bypass the repo-root
  cleanliness gate when preparing the execution worktree.
- The bypass is explicit and opt-in so the default behavior still enforces
  committed-state deploys.
- `--bastion-trigger` forwards `--dirty` to the remote invocation so local and
  remote operator flows stay consistent.
- Help text for `--dirty`, `--force`, and `--dry` stays concise and describes
  behavior without enumerating every compatible action.
