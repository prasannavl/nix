# GitHub Actions workflow design (2026-03)

## Workflow shape

The `nixbot` GitHub Actions workflow (`.github/workflows/nixbot.yaml`) is a thin
launcher: install Nix, warm local runtime closures, lint, and trigger the
bastion-hosted deploy flow. The bastion maintains its own persistent
repo/store/worktree state and does not consume the GitHub Actions cache backend.

## Action input scope

- The deploy script (`scripts/nixbot.sh`) supports arbitrary configured
  Terraform project actions via `--action tf/<project>`.
- The GitHub workflow intentionally exposes only the standard deploy and
  Terraform phase actions as a fixed dropdown for ergonomics.
- Validation is centralized in `scripts/nixbot.sh`, which rejects unsupported
  actions.

## Runtime warmup strategy

- Keep the explicit `nix/deps` warmup step that realizes the `lint` and `nixbot`
  runtime closures before the main lint and bastion-trigger steps.
- Do not use `magic-nix-cache-action`; the extra cache upload/download layer
  adds complexity without improving the bastion-side execution path.
- Treat GitHub Actions warmup as local runner priming only.
- Reintroduce a CI-side binary cache layer only if future workflow timings show
  a material benefit on the runner itself, independent of bastion execution.

## Superseded notes

- `github-actions-custom-action-input-2026-03.md`
- `github-actions-runtime-warmup-without-cache-2026-03.md`
