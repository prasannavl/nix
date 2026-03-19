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

Build/stage model:

- `tf/*-apps` projects may declare a matching aggregate package at
  `pkgs/<project>/flake.nix`.
- Before OpenTofu plan/apply, `scripts/nixbot-deploy.sh` runs the aggregate
  `pkgs/<project>#stage` helper.
- For this project, `pkgs/cloudflare-apps/flake.nix` is the aggregate entrypoint
  and stages each child app by calling that app's `#stage` helper.
- Child app `#stage` helpers are responsible for creating any stable local path
  Terraform needs, such as a store-backed `result` symlink.

Inputs live in `workers.auto.tfvars` plus encrypted account/worker inputs under
`data/secrets/tf/cloudflare/`.
