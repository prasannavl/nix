# Agent Shell Guards

## Scope

- `users/pvl/pi/rm-guard/` is the repository-owned guard on Pi agent shells.
- It is an accident brake for `rm -rf`, not a sandbox: it refuses obvious
  catastrophes and lets the user decide the rest.

## Contract

Recursive removal is checked against the expanded, resolved operand before
anything is removed; all operands are checked first, so one refusal removes
nothing.

| Refused                                                 | Allowed                                                                      |
| ------------------------------------------------------- | ---------------------------------------------------------------------------- |
| `/` and paths one or two levels below it                | non-recursive removal                                                        |
| `$HOME`, its top-level entries and its ancestors        | `$HOME` subdirectories other than top-level entries                          |
| the working directory and its ancestors                 | children of the working directory (`rm -rf node_modules`)                    |
| Git repositories, worktrees and `.git`                  | trees without a repository up to four levels down                            |
| directories holding a repository up to four levels down | anything strictly inside a `tmp` directory, `/dev/shm` or `$XDG_RUNTIME_DIR` |

A `tmp` path only gets the working-directory rule. Symlink operands without a
trailing slash remove the link, so they are not resolved.

## Implementation

- `rm.sh` — rule engine, no shebang of its own: `users/pvl/pi/default.nix` bakes
  it into `writeShellApplication { name = "rm"; }`, which supplies bash,
  `set -euo pipefail` and a shellcheck gate at build time.
- `index.ts` — `tool_call` hook that prefixes the shim. `bash`, `bash_bg` and
  `monitor` get PATH plus an exported `rm` function; `until` gets the PATH entry
  only, because its condition runs under `$SHELL` (a non-POSIX `$SHELL` such as
  fish cannot take the injected `export`, so those sessions only get the bash
  tools guarded). Unlisted tools are patched by nobody, so a new shell-carrying
  tool must be added to `commandTools` or `conditionTools`.
- `@rmGuardBin@` is substituted with `pkgs.replaceVars` into
  `~/.pi/agent/extensions/rm-guard.ts`.

## Accepted Bypasses

- an absolute `rm` path (never through PATH) skips the shim
- `env -i`, and any shell that resets both PATH and the exported function
- a symlink swapped between the check and the final `exec` (no TOCTOU lock)
- deletion that does not go through `rm`: `find -delete`, `git clean -xdf`,
  `shred`, `truncate`, `rmdir`, and MCP shell servers
- `rm -rf *` inside a repository empties the worktree; only the repository root
  and its ancestors are protected

## Maintenance

- Rule change: exercise it in a read-only sandbox (`bwrap --ro-bind / /` with a
  fake `rm` first in PATH) before trusting it; the refusals must keep working
  for `/`, `$HOME`, the working directory and repositories.
- Keep the refusal message actionable: it tells the user to run the command.
