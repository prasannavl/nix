# Repo Tooling

## Scope

Canonical tooling rules for Bash entrypoints, lint and fmt orchestration,
package-local verification, human docs maintenance, and small shared maintenance
scripts.

## Bash entrypoint rules

- Repo Bash entrypoints should use:
  - `#!/usr/bin/env bash`
  - `set -Eeuo pipefail`
- Keep executable flow inside functions.
- Initialize shared runtime state in `init_vars`.
- Own runtime-shell setup inside `ensure_runtime_shell`.
- Thin wrappers may skip their own runtime-shell bootstrap only when the
  delegated entrypoint already owns that responsibility.
- Grouped `local` declarations are allowed when readability stays clear.

## Lint and fmt contract

- `nix run .#lint` is the canonical lint entrypoint.
- Plain lint must stay read-only and CI-safe.
- Fix behavior remains explicit under `nix run .#lint -- fix`.
- `nix fmt` and the repo formatter should own Markdown formatting through
  `deno fmt`; line-length lint should not fight the formatter.
- Respect real CLI limits for wrapped tools such as `statix fix`.
- Keep `nix flake check --no-build` in the baseline lint path.
- Pre-push diff-scoped lint is the preferred local Git hook. The hook should
  cover the pushed range in one run rather than gating every commit.

## Package-local verification

- Root tooling owns files outside `pkgs/`.
- Child flakes under `pkgs/` own their language-specific checks and fix flows
  through the shared package contract.
- Shared helper libraries should own language conventions end to end where
  practical so child flakes do not repeat boilerplate.

## Human docs and commands

- Human-facing docs should front-load purpose, commands, key rules, and
  declaration shapes.
- Prefer short root-exported commands such as `nix run .#lint` and
  `nix build .#<name>` when the root export exists.
- Keep package-local commands only where the package intentionally exposes a
  non-root workflow.
- `README.md` should carry a concise contributing section that points at the
  canonical formatter, lint entrypoint, and hook installer.

## Small maintenance conventions

- `scripts/update-flakes.sh` is the repo-wide flake-lock updater.
- VS Code packaging and update automation should stay explicit about upstream
  source, pinned hashes, and toolchain dependencies needed by the configured
  extensions.

## Source of truth files

- `docs/ai/lang-patterns/bash.md`
- `docs/ai/lang-patterns/markdown.md`
- `scripts/lint.sh`
- `scripts/fmt.sh`
- `scripts/git-install-hooks.sh`
- `scripts/update-flakes.sh`
- `lib/flake/lint.nix`
- `lib/flake/pkg-helper.nix`
- `README.md`

## Provenance

- This note replaces the earlier dated Bash, lint, helper, docs-maintenance,
  package-contract, and small-tooling notes from March and April 2026.
