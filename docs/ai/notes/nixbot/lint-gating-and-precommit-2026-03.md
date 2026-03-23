# Lint gating and pre-commit - 2026-03

- Added a shared flake app/package entrypoint so `nix run path:.#lint` is the
  canonical lint command. Scope and autofix behavior are now selected with
  runtime args: `nix run path:.#lint -- deps`, `nix run path:.#lint`,
  `nix run path:.#lint -- --diff`, `nix run path:.#lint -- fix`, and
  `nix run path:.#lint -- fix --diff`.
- The canonical lint implementation now lives in `scripts/lint.sh`, while
  `lib/flake/lint.nix` stays lean and only packages that script into the flake
  app/output wiring.
- Current repo-wide lint scope is the shared formatter and linter suite across
  the full repo, including read-only formatter checks (`alejandra --check`,
  `deno fmt --check`, and `tofu fmt -check -write=false`), `statix`, `deadnix`,
  `shellcheck`, `actionlint`, `markdownlint-cli2`, and `tflint` over the tracked
  Terraform/OpenTofu project directories.
- `lint fix` runs the fix-capable tools (`treefmt`, `statix fix`,
  `markdownlint-cli2 --fix`, and `tflint --fix`) and then re-runs the regular
  lint suite so any remaining `deadnix`, `shellcheck`, `actionlint`, or
  non-fixable diagnostics still fail visibly.
- `lint --diff` keeps the incremental mode for `statix`, `deadnix`,
  `shellcheck`, and `markdownlint-cli2`, which avoids blocking local commits on
  unrelated repository-wide lint debt while still preventing new drift in
  touched files.
- `lint fix --diff` is the diff-scoped autofix companion for changed-file
  cleanup before re-running the incremental lint gates.
- The lint script now follows the same action-dispatch style as `nixbot`, with
  `deps` and `check-deps` actions instead of a separate `.#lint-deps` package.
- GitHub Actions `nixbot` workflow now runs lint before warming the deploy
  runtime or triggering bastion execution, so formatting failures stop the run
  early.
- On CI, bare `nix run path:.#lint` defaults to diff scope unless an explicit
  scope flag such as `--full` is passed.
- CI now warms lint via `nix run path:.#lint -- deps >/dev/null`, which realizes
  the runnable wrapper and verifies the runtime commands before the actual lint
  step.
- Git pre-commit hook was replaced by a pre-push hook that lints each commit
  individually as a diff. See
  `docs/ai/notes/tooling/pre-push-per-commit-lint-2026-03.md` for details.
- The flake-packaged `lint` wrapper must provide the lint runtime itself and
  `exec` the packaged `scripts/lint.sh` with `LINT_IN_NIX_SHELL=1`. Re-entering
  `ensure_runtime_shell` from the store snapshot makes the script derive
  `--inputs-from` from `/nix/store/...-source`, which Git rejects as
  foreign-owned during local `nix run path:.#lint` and pre-commit invocations.
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
