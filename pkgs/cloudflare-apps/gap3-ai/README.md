# gap3-ai

This directory contains the repo-local source for the `gap3-ai` assets-only
Cloudflare Worker serving `gap3.ai`.

Layout:

- source files at repo root: `index.html`
- Cloudflare config: `wrangler.jsonc`
- flake entrypoint: `pkgs/cloudflare-apps/gap3-ai/flake.nix`

## Flake Commands

- `nix build path:.#build`: build the static output in the Nix store
- `nix run path:.#wrangler-deploy`: build the store output and deploy directly
  with Wrangler

## Root Flake Commands

- `nix build .#pkgs.x86_64-linux.cloudflare-apps.gap3-ai`
- `nix run .#pkgs.x86_64-linux.cloudflare-apps.gap3-ai.wrangler-deploy`

## Deploy Modes

- aggregate Terraform deploy: build apps via `pkgs/cloudflare-apps#build`, then
  run the repo's Terraform reconciliation via `nixbot tf-apps`
- app `wrangler-deploy`: a direct Wrangler deploy path for this app only; useful
  for ad-hoc iteration when you explicitly want to bypass the Terraform flow

The Worker definition is in:

- `tf/cloudflare-apps/workers.auto.tfvars`
