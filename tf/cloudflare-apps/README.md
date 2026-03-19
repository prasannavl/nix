# OpenTofu Cloudflare Apps

This project manages Cloudflare application-layer resources that run after host
build/deploy work.

Scope:

- Workers
- Worker routes
- Worker custom domains

Runtime:

- `./scripts/nixbot-deploy.sh --action tf-apps`
- default state key: `cloudflare-apps/terraform.tfstate`

Build model:

- `tf/*-apps` projects may declare a matching aggregate package at
  `pkgs/<project>/flake.nix`.
- Before OpenTofu plan/apply, `scripts/nixbot-deploy.sh` runs the aggregate
  `pkgs/<project>#build` derivation with `nix build --no-link`.
- For this project, `pkgs/cloudflare-apps/flake.nix` is the aggregate entrypoint.
- Child app directories are resolved to their `#build` outputs by the
  Cloudflare module's worker asset resolver during plan/apply.

Inputs live in `workers.auto.tfvars` plus encrypted account/worker inputs under
`data/secrets/tf/cloudflare/`.
