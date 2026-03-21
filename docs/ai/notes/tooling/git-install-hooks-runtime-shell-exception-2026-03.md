# Git Install Hooks Runtime Shell Exception 2026-03

## Context

- `scripts/git-install-hooks.sh` only configures `core.hooksPath` in an already
  cloned Git repository.
- The script is expected to run in an environment where `git` is already present
  because Git was required to clone or operate on the repo in the first place.

## Decision

- Removed the redundant `ensure_runtime_shell` wrapper from
  `scripts/git-install-hooks.sh`.
- Kept the script as a minimal helper that resolves the repo root and runs the
  required Git config command directly.

## Result

- The helper stays simple and avoids unnecessary runtime bootstrapping.
- This follows the Bash wrapper exception model where local environment
  assumptions are already guaranteed by the calling context.
