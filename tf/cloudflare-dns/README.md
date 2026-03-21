# OpenTofu Cloudflare DNS

This project is the pre-deploy Cloudflare DNS phase.

Scope:

- public-safe DNS records from `dns.auto.tfvars`
- provider-wide encrypted inputs from `data/secrets/tf/cloudflare/*.tfvars.age`
- project-specific encrypted DNS records from
  `data/secrets/tf/cloudflare-dns/*.tfvars.age`

Runtime:

- `nixbot tf-dns`
- default state key: `cloudflare-dns/terraform.tfstate`

This project reuses `tf/modules/cloudflare/` and preserves the existing DNS
state key from the old monolithic Cloudflare project.
