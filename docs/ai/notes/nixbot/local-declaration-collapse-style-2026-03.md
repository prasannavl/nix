# Nixbot local declaration collapse style

- Date: 2026-03-22
- Scope: `docs/ai/lang-patterns/bash.md`, `pkgs/nixbot/nixbot.sh`

## Context

The repo Bash pattern originally required one `local` declaration per line. The
user explicitly requested grouped local declarations and asked to update the
rule before applying that style to `nixbot`.

## Decision

- Bash files may group related `local` declarations into one statement when the
  result remains readable.
- Mixed declaration forms should still stay split when grouping would blur
  array/nameref attributes or interfere with nearby comments.
- `pkgs/nixbot/nixbot.sh` is the first file updated under the new rule.

## Implementation notes

- Collapse adjacent compatible `local` lines into grouped statements.
- Initialize previously bare scalar locals on the declaration line when that
  keeps the grouped form straightforward under `set -u`.
- Preserve separate lines around shellcheck directives and mixed `local` forms
  such as plain locals versus `local -a` / `local -n`.
