# Pre-push range-based lint - 2026-03

## Change

Replaced the `pre-commit` hook with a `pre-push` hook that lints all files
changed across the pushed commit range in a single invocation. Also added
`nix flake check` for subprojects whose files appear in the changed set.

## Motivation

- **Developer experience** — pre-commit hooks penalize every commit, adding
  friction during exploratory work. Developers typically work on PR branches
  with several commits, iterating freely before pushing. Moving lint to pre-push
  lets them commit without interruption while still catching issues before code
  leaves their machine.
- **CI is the real gate** — PRs run the full lint and check suite anyway, so
  everything that lands on master is clean regardless. The pre-push hook is a
  convenience safety net, not the source of truth for correctness.
- **Simplicity** — a single `--diff --base <range_start>` invocation over the
  full pushed range is simpler and faster than per-commit checkout loops.

## Implementation

- `.githooks/pre-push` reads stdin for pushed refs, computes the commit range
  via `git rev-list --count`, and runs
  `nix run .#lint -- --diff --base <range_start>`.
- For new branches, merge-base is computed against `origin/HEAD` (falling back
  to `master`).
- No checkout or stash needed — lint runs against the current working tree with
  the diff file list derived from the range.
- `scripts/lint.sh` gained a `collect_changed_flake_dirs` helper that discovers
  subproject `flake.nix` files under `pkgs/` and matches them against changed
  files. When a subproject has changes, `nix flake check` runs for it as a new
  `flake-check` lint step.
- `.githooks/pre-commit` removed.

## Trade-offs

- Does not guarantee each commit is independently lint-clean — only that the
  cumulative diff is clean. This is acceptable because CI enforces the full
  suite on every PR before merge.
- Unlinted commits can accumulate locally until push time, but this is the
  intended trade-off for faster local iteration.
