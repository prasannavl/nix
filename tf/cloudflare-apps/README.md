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

- app phases may declare an aggregate package at `pkgs/<project>/flake.nix`
- `nixbot` prepares the phase with `nix build ./pkgs/<project>#build --no-link`
- for this project, the aggregate entrypoint is `pkgs/cloudflare-apps/flake.nix`
- child app directories are resolved to their `#build` outputs during plan/apply

Inputs live in `workers.auto.tfvars` plus encrypted provider-level inputs under
`data/secrets/tf/cloudflare/` and project-level worker inputs under
`data/secrets/tf/cloudflare-apps/`.
