# Bash

## Scope

- Treat `scripts/*.sh` as standardized Bash entrypoints unless the user says
  otherwise.

## File structure

- Start Bash scripts with exactly:
  - `#!/usr/bin/env bash`
  - `set -Eeuo pipefail`
- Blank lines for readability are fine.
- Keep executable logic inside functions.
- Top-level code should be limited to function definitions plus the final
  `main "$@"` call.
- Do not leave stray top-level executable lines outside functions.

## Initialization

- If a script needs shared/default variables, gather them in one `init_vars`
  helper.
- Call `init_vars` at the start of `main` after runtime-shell setup.

## Runtime dependencies

- If a script depends on runtime tools, provide an `ensure_runtime_shell`
  helper.
- `ensure_runtime_shell` should re-exec through `nix shell --inputs-from ...`
  with the required packages.
- Keep recursion-guard env vars local to `ensure_runtime_shell` instead of
  storing them as top-level globals.
- Exception: wrapper scripts do not need their own `ensure_runtime_shell` when
  they immediately delegate to another repo script or entrypoint that already
  owns runtime dependency setup and `nix shell` re-exec behavior.
