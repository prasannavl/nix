# Lint modes cleanup and root flake check

## Root flake check

`nix flake check --no-build` now runs on the root flake in every lint mode.
This validates that all flake outputs evaluate without errors.

## Lint modes

Four clean modes replacing the old `--diff`/`--full`/`--ci` flags:

### auto (default, no flags)

- Diff lints against `origin/master` (overridable with `--base`)
- Full flake checks on changed sub-projects only

### --diff --base REF

- Diff lints against the specified ref
- Full flake checks on changed sub-projects only
- `--base` is required with `--diff`

### --full-no-test

- Full lints on all files
- Flake checks on all sub-projects, but skip `test` and `test-*` checks
- Good for CI on PRs: catches build/lint regressions everywhere without
  running expensive test suites on untouched code

### --full

- Full lints on all files
- Full flake checks on all sub-projects including tests
- For merge-to-master or scheduled runs

## Convention

Sub-flakes should name their test checks `test` or `test-*` so the
`--full-no-test` filter works. `hello-rust` already follows this.

## Implementation

- `LINT_MODE` variable: `auto`, `diff`, `full-no-test`, `full`
- `lint_scope()` helper maps modes to `diff` or `full` for file collection
- `collect_all_flake_dirs`: enumerates all sub-flake dirs under `pkgs/`
- `run_flake_checks_skip_test`: enumerates checks via `nix flake show --json`,
  filters out test attrs, builds the rest with `nix build --no-link`
- `detect_nix_system`: `nix eval --raw --impure --expr 'builtins.currentSystem'`
- `jq` added to lint runtime deps (both `scripts/lint.sh` and
  `lib/flake/lint.nix`)

## Mode matrix

| Mode             | Lint scope      | Root check | Sub-flake checks             |
| ---------------- | --------------- | ---------- | ---------------------------- |
| auto             | diff to master  | yes        | changed only, full           |
| `--diff`         | diff to REF     | yes        | changed only, full           |
| `--full-no-test` | all files       | yes        | all sub-projects, skip test  |
| `--full`         | all files       | yes        | all sub-projects, full       |
