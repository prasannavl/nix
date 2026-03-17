# OpenTofu Cloudflare Platform

This project manages non-app Cloudflare infrastructure that is safe to run
outside the host build itself.

Scope:

- account metadata like KV namespaces, Email Routing destination addresses, and
  Zero Trust Access
- R2 buckets
- zone DNSSEC
- zone settings, security, rules, cache, and Email Routing

Runtime:

- `./scripts/nixbot-deploy.sh --action tf-platform`
- default state key: `cloudflare-platform/terraform.tfstate`

Inputs live in this directory's `*.auto.tfvars` files plus encrypted inputs
under `data/secrets/tf/cloudflare/`.
