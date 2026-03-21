# Lint gating and pre-commit - 2026-03

- Added flake app/package entrypoints so `nix run path:.#lint` is the canonical
  whole-repo lint command and `nix run path:.#lint-diff` preserves the earlier
  diff-scoped local workflow.
- The lint implementation lives in `lib/flake/lint.nix` so the root `flake.nix`
  stays lean and only wires the per-system outputs.
- Current repo-wide lint scope is the shared formatter and linter suite across
  the full repo, including `treefmt --ci`, `statix`, `deadnix`, `shellcheck`,
  `actionlint`, `markdownlint-cli2`, and `tflint` over the tracked
  Terraform/OpenTofu project directories.
- `lint-diff` keeps the incremental mode for `statix`, `deadnix`, `shellcheck`,
  and `markdownlint-cli2`, which avoids blocking local commits on unrelated
  repository-wide lint debt while still preventing new drift in touched files.
- GitHub Actions `nixbot` workflow now runs lint before warming the deploy
  runtime or triggering bastion execution, so formatting failures stop the run
  early.
- The lint toolchain is exported separately as flake package `.#lint-deps` so CI
  can warm it in a dedicated step with `nix build path:.#lint-deps >/dev/null`
  and keep the actual `nix run path:.#lint` logs focused on lint output while
  also prebuilding `.#lint-diff`.
- `.#lint-deps` now includes the runnable `writeShellApplication` wrapper
  closures for both `.#lint` and `.#lint-diff`, not only the top-level lint
  binaries, because warming just the tool packages still left the wrappers to
  realize their derivations and fetch builder-time dependencies such as
  `makeWrapper`.
- Git pre-commit is wired through `.githooks/pre-commit` and now calls
  `nix run path:.#lint-diff`, while CI stays on `nix run path:.#lint`.
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
