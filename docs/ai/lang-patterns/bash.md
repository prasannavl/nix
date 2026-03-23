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

## Variable declarations

- Prefer collapsing related `local` declarations into a single statement when it
  stays readable.
- Split locals across multiple lines when different attributes (`-a`, `-n`,
  etc.), inline comments, or control-flow-adjacent setup make the combined form
  harder to scan.

## Namerefs

- Avoid `local -n` by default.
- Prefer plain values and explicit returns:
  - for one scalar value, print it and capture with `var="$(helper ...)"`.
  - for a few scalar values, print one per line and read them with a grouped
    `read`.
  - for tightly coupled helper state, prefer an explicit shared context object
    or script-global staging variables over scalar by-reference plumbing.
- Before converting a helper to stdout/capture, check whether it also mutates
  process-global state. Command substitution runs in a subshell, so config
  initialization, temp-dir setup, cached state, and staged context do not
  survive in the caller unless that state is established first in the parent
  shell.
- Use `local -n` only when by-reference mutation is materially simpler than the
  alternatives, such as:
  - mutating arrays in place
  - updating counters or accumulators in tight helper loops
  - narrow, well-contained summary aggregation where copying would be awkward
- Also allow `local -n` or another in-process return pattern when the helper
  must both return a value and preserve caller-visible global mutations.
- Even when `local -n` is justified:
  - keep the scope tight
  - use function-specific alias names
  - do not forward helper-local alias names to nested helpers; forward the
    original target-name strings instead
  - do not declare scratch locals that reuse likely caller output names
    (`ssh_target`, `status`, `result_kind`, etc.)
- If a helper only returns scalar values and does not need in-place mutation,
  `local -n` is usually the wrong tool.

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
