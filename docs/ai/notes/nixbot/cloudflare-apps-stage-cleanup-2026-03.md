# Cloudflare Apps Stage Cleanup (2026-03)

## Scope

Durable note for removing the old Cloudflare apps `stage` flow after Terraform
gained direct resolution from repo-local app directories to Nix `#build`
outputs.

## Decision

- `scripts/nixbot-deploy.sh` now warms `tf/*-apps` projects with
  `nix build path:pkgs/<project>#build --no-link` instead of
  `nix run ...#stage`.
- `pkgs/cloudflare-apps/flake.nix` no longer exposes aggregate `stage` helpers.
- `pkgs/cloudflare-apps/llmug-hello/flake.nix` no longer creates a repo-local
  `result` symlink for Terraform or Wrangler deploy.
- Direct Wrangler deploy now resolves the `#build` store path and passes it via
  `wrangler deploy --assets <store-path>`.

## Result

- Terraform no longer depends on repo-local staged output.
- Cloudflare app build flow is reduced to `build` plus optional deploy helpers.
