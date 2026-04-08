# Linting

This repo splits formatting and linting into two layers:

- Root tooling owns files outside `pkgs/`.
- Package-local flakes own language-specific formatting, linting, and tests
  inside `pkgs/`.

## Main Commands

- `nix fmt`: format the repo root and then package-owned files.
- `nix run .#lint`: run the standard read-only lint and check flow.
- `nix run .#lint -- --full`: run the full lint scope explicitly.
- `nix run .#lint -- fix`: apply safe auto-fixes, then re-run lint.
- `nix run .#lint -- --diff`: lint only changed files and changed packages.
- `nix run .#lint -- fix --diff`: apply diff-scoped auto-fixes, then re-run
  diff-scoped lint.
- `nix run .#lint -- --project <name>`: limit package work to selected child
  flakes.
- `nix run .#fmt -- --project <name>`: limit formatting to selected child
  flakes.

## Git Hooks

Install the repo hooks once with:

```sh
./scripts/git-install-hooks.sh
```

The repo uses a `pre-push` hook, not a `pre-commit` hook:

- commit-time iteration stays fast
- lint still runs before code leaves your machine
- the hook computes the push base and only lints the changed scope

The hook runs the same diff-based flow directly:

```sh
nix run .#lint -- --diff --base <base>
```

## Ownership Model

Root tooling handles files outside `pkgs/`:

- `nix fmt` formats root-managed files.
- `nix run .#lint` runs root-managed checks.
- `nix run .#lint -- fix` runs root-managed fixers.

Package tooling handles files inside child flakes:

- `#fmt`: format package-owned files
- `#lint-fix`: apply package-owned auto-fixes
- `#checks.fmt`: verify formatting
- `#checks.lint`: verify lint rules
- `#checks.test`: run tests

`checks.*` stay read-only. Mutating behavior belongs in package apps such as
`fmt` and `lint-fix`.

## Common Package Commands

From the repo root:

- `nix build ./pkgs/<name>`
- `nix run ./pkgs/<name>`
- `nix run ./pkgs/<name>#dev`
- `nix run ./pkgs/<name>#fmt`
- `nix run ./pkgs/<name>#lint-fix`
- `nix build ./pkgs/<name>#checks.fmt`
- `nix build ./pkgs/<name>#checks.lint`
- `nix build ./pkgs/<name>#checks.test`
- `nix flake check ./pkgs/<name>`

## Root Tooling

Root-owned formatter policy outside `pkgs/` is intentionally narrow:

- Markdown, JSON, JSONC: `deno fmt`
- Nix: `alejandra`
- Terraform and OpenTofu: `tofu fmt`
- Shell: `shfmt`

Root lint also includes:

- `statix`
- `deadnix`
- `shellcheck`
- `markdownlint-cli2`
- `actionlint`
- `tflint`

## Package Conventions

Package-local flakes under `pkgs/` conventionally expose:

- `checks.fmt`
- `checks.lint`
- `checks.test`
- `apps.fmt`
- `apps.lint-fix`
- `apps.dev` when the package has a runnable dev workflow

Shared flake helpers define the default package language policy:

- Rust: `rustfmt`, `clippy`, `cargo test`
- Python: `ruff`
- Go: `gofmt`, `go vet`, `go test`
- Web projects: `biome`

The package-helper contract is documented in
[`docs/flake-package.md`](./flake-package.md).

## CI Behavior

- CI warms the lint runtime with `nix run .#lint -- deps`.
- When `CI` is set, bare `nix run .#lint` defaults to diff scope unless an
  explicit scope such as `--full` is passed.
