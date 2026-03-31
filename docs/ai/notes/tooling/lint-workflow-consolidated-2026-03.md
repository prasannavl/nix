# Lint Workflow Consolidated (2026-03)

## Scope

Canonical March 2026 summary of the repo lint contract, especially read-only
validation behavior and the `statix fix` invocation constraint.

## Durable lint contract

- `nix run path:.#lint` is the canonical lint entrypoint.
- The non-fix lint path must be read-only: validating formatting must not
  rewrite files as a side effect.
- `nix run path:.#lint -- fix` remains the explicit mutation path for
  formatter/autofix tooling.

## Read-only formatting rule

- Plain lint must use formatter-native check flags rather than `treefmt --ci`.
- The durable check-mode commands are:
  - `alejandra --check` for Nix
  - `deno fmt --check` for JavaScript and Markdown
  - `tofu fmt -check -write=false -diff -recursive` for Terraform/OpenTofu
- `treefmt` remains appropriate only for the explicit fix path, where file
  mutation is expected.

## `statix fix` constraint

- `scripts/lint.sh` must not pass multiple positional file arguments to
  `statix fix`.
- The current CLI accepts only one optional positional target, so explicit file
  handling must invoke `statix fix` once per selected file.
- This restriction matters for both diff-scoped and full-repo fix flows when
  operating on explicit path lists.
- `statix check` can still run per file as usual; the constraint is specific to
  the autofix subcommand.

## Practical interpretation

- Treat the default lint command as CI-safe and side-effect free.
- Keep fix behavior explicit and opt-in.
- When wrapping lint tools with path selection, respect each tool's real CLI
  contract instead of assuming batch positional arguments are supported.

## Modes and baseline checks

- Every lint mode should include `nix flake check --no-build` on the root flake.
- The durable mode split is:
  - `auto`: diff to the default base, changed sub-flakes only
  - `--diff --base <ref>`: diff to the explicit base, changed sub-flakes only
  - `--full-no-test`: full lint plus all sub-flakes except `test` / `test-*`
    checks
  - `--full`: full lint plus full sub-flake checks
- Sub-flakes should name expensive checks `test` or `test-*` so mode-based
  filtering stays mechanical.

## Recent cleanup pattern

- Notes that only say "the current lint failures were cleared" are transient by
  nature. Keep the durable lint contract here rather than preserving one file
  per cleanup pass.

## Superseded notes

- `docs/ai/notes/tooling/lint-readonly-format-checks-2026-03.md`
- `docs/ai/notes/tooling/lint-statix-fix-cli-2026-03.md`
- `docs/ai/notes/tooling/lint-ci-mode-and-root-check-2026-03.md`
- `docs/ai/notes/tooling/lint-fixes-2026-03.md`
