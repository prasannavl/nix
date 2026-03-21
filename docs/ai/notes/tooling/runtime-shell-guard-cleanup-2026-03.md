# Runtime Shell Guard Cleanup 2026-03

## Context

- Several repo helper scripts re-exec themselves through `nix shell` and use an
  env var guard to avoid recursive re-entry.
- Those scripts carried a top-level `RUNTIME_SHELL_FLAG` global even when the
  value was only read inside `ensure_runtime_shell`.

## Decision

- Standardized the pattern so each script reads its `*_IN_NIX_SHELL` env var
  directly inside `ensure_runtime_shell`.
- Removed the redundant top-level `RUNTIME_SHELL_FLAG` globals from:
  - `scripts/update-fetchzip-in-derv-hashes.sh`
  - `scripts/update-gnome-ext.sh`
  - `scripts/update-nvidia.sh`
- Kept the env var names and `nix shell` re-exec behavior unchanged.

## Result

- Runtime-shell recursion guards now live at their only point of use.
- Script startup state is cleaner and less global by default.
