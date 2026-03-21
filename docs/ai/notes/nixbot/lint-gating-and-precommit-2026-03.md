# Lint gating and pre-commit - 2026-03

- Added a flake app/package entrypoint so `nix run path:.#lint` is the canonical
  repo lint command.
- The lint implementation lives in `lib/internal/lint.nix` so the root
  `flake.nix` stays lean and only wires the per-system outputs.
- Current repo-wide lint scope is `treefmt --ci`, `actionlint`, and `tflint`
  over the tracked Terraform/OpenTofu project directories.
- `statix`, `deadnix`, `shellcheck`, and `markdownlint-cli2` were adopted in an
  incremental mode that checks changed files only, which avoids blocking on
  existing repository-wide lint debt while still preventing new drift.
- GitHub Actions `nixbot` workflow now runs lint before warming the deploy
  runtime or triggering bastion execution, so formatting failures stop the run
  early.
- The lint toolchain is exported separately as flake package `.#lint-deps` so CI
  can warm it in a dedicated step with `nix build path:.#lint-deps >/dev/null`
  and keep the actual `nix run path:.#lint` logs focused on lint output.
- `.#lint-deps` now includes the runnable `writeShellApplication` wrapper
  closure for `.#lint`, not only the top-level lint binaries, because warming
  just the tool packages still left `nix/lint` to realize `lint.drv` and fetch
  builder-time dependencies such as `makeWrapper`.
- Git pre-commit is wired through `.githooks/pre-commit` and calls the same
  `nix run path:.#lint` command to keep local and CI behavior aligned.
- The lint wrapper now tracks the active step and emits a final
  `[lint] FAILED at <step>: <description>` summary on non-zero exit so Git UIs
  such as VS Code surface the failing linter more clearly than the earlier
  progress banner.
- The pre-commit hook and lint entrypoint now emit an initial top-level banner
  before step logs so Git clients do not reduce hook failures to the first
  `treefmt` progress line when a later linter fails.
- Markdown lint is configured through `.markdownlint-cli2.jsonc` to disable
  `MD013` line-length checks, matching the repo choice to let `deno fmt` own
  Markdown wrapping while still keeping structural Markdown rules enforced.
