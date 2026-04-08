# llmug-hello

This directory contains the repo-local source for the `llmug-hello` assets-only
Cloudflare Worker.

Layout:

- source files at repo root: `index.html`, `favicon.ico`, `css/`, `js/`,
  `icons/`
- Cloudflare config: `wrangler.jsonc`
- flake entrypoint: `pkgs/cloudflare-apps/llmug-hello/flake.nix`

## Flake Commands

- `nix build .#build`: build the static output in the Nix store
- `nix run .#dev`: serve the built static output locally on `127.0.0.1:8080`
- `nix run .#wrangler-deploy`: build the store output and deploy directly with
  Wrangler
- `nix run .#lint`: run `biome check .`
- `nix run .#fix`: run `biome check --write .`

## Root Flake Commands

- `nix build ./pkgs/cloudflare-apps/llmug-hello#build`
- `nix run ./pkgs/cloudflare-apps/llmug-hello#dev`
- `nix run ./pkgs/cloudflare-apps/llmug-hello#wrangler-deploy`

## Deploy Modes

- aggregate Terraform deploy: build apps via `pkgs/cloudflare-apps#build`, then
  run the repo's Terraform reconciliation via `nixbot tf-apps`
- app `dev`: a local preview server for the built static assets; useful for
  checking the packaged output without deploying
- app `wrangler-deploy`: a direct Wrangler deploy path for this app only; useful
  for ad-hoc iteration when you explicitly want to bypass the Terraform flow

The Worker definition is in:

- `data/secrets/tf/cloudflare/workers/stage.tfvars.age`
