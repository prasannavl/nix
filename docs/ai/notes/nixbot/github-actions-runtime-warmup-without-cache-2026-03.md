# GitHub Actions runtime warmup without cache (2026-03)

## Scope

Canonical March 2026 decision for the `nixbot` GitHub Actions workflow's local
Nix runtime preparation.

## Decision

- Keep the explicit `nix/deps` warmup step that realizes the `lint` and `nixbot`
  runtime closures before the main lint and bastion-trigger steps.
- Remove the `magic-nix-cache-action` step from `.github/workflows/nixbot.yaml`.

## Rationale

- This workflow is primarily a thin launcher: install Nix, warm the local
  runtime closures, lint, and trigger the bastion-hosted deploy flow.
- The bastion maintains its own persistent repo/store/worktree state and does
  not consume the GitHub Actions cache backend.
- For this workflow shape, the extra cache upload/download layer adds complexity
  without improving the bastion-side execution path.

## Practical rule

- Treat GitHub Actions warmup as local runner priming only.
- Reintroduce a CI-side binary cache layer only if future workflow timings show
  a material benefit on the runner itself, independent of bastion execution.
