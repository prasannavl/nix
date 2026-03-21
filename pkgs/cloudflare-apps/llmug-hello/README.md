# llmug-hello

This directory contains the repo-local source for the `llmug-hello` assets-only
Cloudflare Worker.

Layout:

- source files at repo root: `index.html`, `favicon.ico`, `css/`, `js/`,
  `icons/`
- Cloudflare config: `wrangler.jsonc`
- flake entrypoint: `pkgs/cloudflare-apps/llmug-hello/flake.nix`

## Flake Commands

- `nix build path:.#build`: build the static output in the Nix store
- `nix run path:.#wrangler-deploy`: build the store output and deploy directly
  with Wrangler
- `nix run path:.#lint`: run `biome check .`
- `nix run path:.#fix`: run `biome check --write .`

## Root Flake Commands

- `nix build .#pkgs.x86_64-linux.cloudflare-apps.llmug-hello`
- `nix run .#pkgs.x86_64-linux.cloudflare-apps.llmug-hello.wrangler-deploy`

## Deploy Modes

- aggregate Terraform deploy: build apps via `pkgs/cloudflare-apps#build`, then
  run the repo's Terraform reconciliation via
  `scripts/nixbot.sh run --action tf-apps`
- app `wrangler-deploy`: a direct Wrangler deploy path for this app only; useful
  for ad-hoc iteration when you explicitly want to bypass the Terraform flow

The Worker definition is in:

- `data/secrets/tf/cloudflare/workers/stage.tfvars.age`
