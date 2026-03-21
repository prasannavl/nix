# Age Secrets Clean Flag 2026-03

## Context

- `scripts/age-secrets.sh` already supported `encrypt`, `decrypt`, and an
  auto-toggle mode over files managed by `data/secrets/default.nix`.
- Decrypting secrets leaves plaintext siblings next to managed `*.age` files.

## Decision

- Added `clean` and `-c` to `scripts/age-secrets.sh`.
- `clean` only targets plaintext files that are the sibling of a managed `*.age`
  entry from `data/secrets/default.nix`.
- The command supports the existing optional directory scope filter so an
  operator can clean all managed plaintext secrets or just one managed subtree.
- Added an `init_vars` helper so runtime defaults such as the decrypt identity
  file are initialized in one place instead of inside `decrypt_file`.
- Expanded `init_vars` to also initialize the repo root, the canonical managed
  secrets path, and the empty default target scope so the script's built-in
  paths/defaults are visible in one section.
- Moved the default assignments themselves into `init_vars` so that helper is
  now the only place where the script's built-in defaults are defined.
- Removed the redundant top-level placeholder globals so the script no longer
  carries loose default-related variables outside `init_vars`.
- Refactored the main control flow into smaller helpers for argument parsing,
  target-directory resolution, candidate collection, empty-state reporting, and
  per-mode execution so `main` now mostly orchestrates those steps.
- Removed the separate managed-secrets path variables from `init_vars`; the
  script now keeps only reused runtime state there and embeds the fixed
  `data/secrets/default.nix` path directly at point of use.
- Reversed that simplification so fixed defaults are again assigned only inside
  `init_vars`, and the rest of the script reads those variables instead of
  embedding the literals at call sites.
- Removed the redundant `MANAGED_SECRETS_REL_PATH` variable; `init_vars` now
  sets only `MANAGED_SECRETS_FILE`, and user-facing messages derive the repo
  relative label from that path when needed.
- Extended the scope filter to accept either a managed directory or a single
  managed file path; plaintext file paths resolve to their managed `.age`
  entries, and managed `.age` file paths resolve directly.
- Decrypt behavior was corrected to keep using the same configured identity for
  all selected files and continue past per-file decrypt failures, reporting a
  failing exit status after the batch instead of aborting on the first failure.
- Fixed two regressions from that batch-decrypt refactor:
  - decrypt temp-file cleanup no longer trips `set -u` via a stale `RETURN` trap
    on `tmp_output`
  - candidate filtering for `clean`/`encrypt` no longer trips `set -e` on
    missing files while scanning the managed set
- Fixed a positional-argument regression in `parse_args` where the explicit
  scope path could be dropped for commands like `clean <path>`, causing the
  command to fall back to the full managed set.
- Added `-v` / `--verbose` output control. By default, decrypt prints only
  successful decrypts and a final failure count; verbose mode restores detailed
  per-file decrypt failure logs and the configured decrypt identity line.
- Replaced the temporary decrypt stderr files with in-memory stderr capture so
  verbose failure details no longer require on-disk `*.err.*` scratch files.
- Folded the runtime nix-shell recursion guard into `ensure_runtime_shell`
  itself so the script no longer carries a top-level `RUNTIME_SHELL_FLAG` global
  that is only consumed in one place.

## Result

- Operators now have an explicit cleanup command for decrypted secrets without
  reusing `encrypt` for deletion semantics.
- Unmanaged plaintext files remain untouched.
