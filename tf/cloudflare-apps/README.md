# OpenTofu Cloudflare Apps

Application-layer Cloudflare phase that runs after host build and deploy.

## Scope

- Workers
- Worker routes
- Worker custom domains

## Runtime

- `nixbot tf-apps`
- default state key: `cloudflare-apps/terraform.tfstate`

## Build Model

- the aggregate package source lives under `pkgs/cloudflare-apps/`
- `nixbot` prepares the phase by building the canonical package
  `pkgs/cloudflare-apps/default.nix` directly
- child app directories are resolved to their package outputs during plan/apply,
  without depending on repo-local `result` symlinks

Inputs live in `workers.auto.tfvars` plus encrypted provider-level inputs under
`data/secrets/globals/tf/cloudflare/` and project-level worker inputs under
`data/secrets/globals/tf/cloudflare-apps/`.
