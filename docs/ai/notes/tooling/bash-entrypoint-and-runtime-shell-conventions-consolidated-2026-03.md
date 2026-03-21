# Bash Entrypoint And Runtime Shell Conventions Consolidated (2026-03)

## Scope

Canonical March 2026 summary of repo Bash entrypoint structure, runtime-shell
re-exec rules, and the allowed exceptions for thin wrapper scripts.

## Durable conventions

- Repo Bash entrypoints should use:
  - `#!/usr/bin/env bash`
  - `set -Eeuo pipefail`
- Executable flow belongs inside functions; avoid stray top-level executable
  lines outside function definitions.
- Shared/default runtime state belongs in `init_vars`.
- Runtime dependency setup belongs in `ensure_runtime_shell`.
- Readable blank lines are fine; the real constraint is to avoid loose
  executable top-level statements.

## Runtime-shell model

- Scripts that need repo-pinned runtime tools should re-exec through `nix shell`
  from `ensure_runtime_shell`.
- Runtime-shell recursion guards should be read directly at the point of use in
  `ensure_runtime_shell`; do not keep redundant top-level `RUNTIME_SHELL_FLAG`
  globals when the value is not used elsewhere.
- This cleanup already landed in helper scripts such as:
  - `scripts/update-fetchzip-in-derv-hashes.sh`
  - `scripts/update-gnome-ext.sh`
  - `scripts/update-nvidia.sh`

## Thin-wrapper exceptions

- A thin wrapper may skip its own `ensure_runtime_shell` only when the delegated
  entrypoint already owns runtime setup.
- `scripts/git-install-hooks.sh` is intentionally one such exception because it
  only configures Git inside an already-cloned repo, where Git is a calling
  precondition.
- The same exception model applies to other minimal pass-through wrappers when
  the delegated script already provides the pinned runtime.

## Practical interpretation

- Prefer one consistent function-based Bash entrypoint pattern across repo
  helpers.
- Keep runtime bootstrap logic explicit and local to `ensure_runtime_shell`.
- Allow wrapper exceptions sparingly, and only when the runtime assumption is
  genuinely guaranteed by the calling context or delegated entrypoint.

## Superseded notes

- `docs/ai/notes/tooling/bash-script-ai-rules-2026-03.md`
- `docs/ai/notes/tooling/git-install-hooks-runtime-shell-exception-2026-03.md`
- `docs/ai/notes/tooling/runtime-shell-guard-cleanup-2026-03.md`
