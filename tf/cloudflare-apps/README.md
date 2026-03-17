# OpenTofu Cloudflare Apps

This project manages Cloudflare application-layer resources that should run
after builds and host deploys.

Scope:

- Workers
- Worker routes
- Worker custom domains

Runtime:

- `./scripts/nixbot-deploy.sh --action tf-apps`
- default state key: `cloudflare-apps/terraform.tfstate`

Inputs live in `workers.auto.tfvars` plus encrypted account/worker inputs under
`data/secrets/tf/cloudflare/`.
