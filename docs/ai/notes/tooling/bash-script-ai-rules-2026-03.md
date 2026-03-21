# Bash Script AI Rules 2026-03

## Context

- Repo helper scripts had drifted in structure and style.
- The desired standard is explicit: compact files, function-only executable
  flow, centralized variable initialization, and `nix shell` runtime re-exec for
  script dependencies.

## Decision

- Added repo-level Bash rules to `AGENTS.md` covering:
  - the required `#!/usr/bin/env bash` plus `set -Eeuo pipefail` header
  - no stray top-level executable lines outside functions
  - executable logic stays inside functions
  - shared/default variable setup belongs in `init_vars`
  - dependency setup belongs in `ensure_runtime_shell`
- Aligned the `scripts/` Bash entrypoints to that standard, including moving
  script-level defaults into `init_vars` and adding runtime-shell wrappers to
  the smaller entrypoints that lacked them.

## Result

- Future agent edits now have a durable repo rule for Bash.
- The canonical Bash guidance now lives in `docs/ai/lang-patterns/bash.md`,
  while `AGENTS.md` points agents to the language-pattern index.
- Spacing guidance was corrected after an over-broad interpretation: readable
  blank lines are allowed; the actual constraint is to avoid loose executable
  top-level lines outside functions.
- Current helper scripts are closer to one consistent entrypoint pattern.
