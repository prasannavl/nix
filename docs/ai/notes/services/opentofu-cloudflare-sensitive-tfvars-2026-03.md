# OpenTofu Cloudflare Sensitive TFVars 2026-03

## Summary

Split Cloudflare DNS Terraform inputs into public-safe and sensitive layers so
origin-bearing or otherwise non-public records can stay encrypted in-repo and
only be decrypted at `--action tf` runtime.

## What Changed

- Added `variable "secret_zones"` alongside `zones` in `tf/variables.tf`.
- Added `variable "secrets"` for reusable encrypted values loaded from the same
  secret tfvars file.
- Updated `tf/main.tf` to merge `zones` and `secret_zones` per zone by
  concatenating their `records` lists before creating `cloudflare_dns_record`
  resources.
- Registered `data/secrets/cloudflare/zones-sensitive.auto.tfvars.age` in
  `data/secrets/default.nix` with the same recipients as the existing
  Cloudflare/R2 Terraform secrets.
- Updated `scripts/nixbot-deploy.sh` so `--action tf` decrypts that encrypted
  tfvars file into its temp dir and passes it to `tofu plan` via `-var-file`
  when present.
- Generalized `scripts/age-secrets.sh` help text so managed non-`.key` files
  are described correctly.

## Operational Notes

- Public-safe records still live in `tf/zones.auto.tfvars` under `zones = {}`.
- Sensitive records belong in
  `data/secrets/cloudflare/zones-sensitive.auto.tfvars.age` under
  `secret_zones = {}`.
- Reusable encrypted values belong in the same file under `secrets = {}` and
  can be referenced as `var.secrets["key"]`.
- `scripts/nixbot-deploy.sh --action tf` continues to work without the
  sensitive tfvars secret; it logs that it is proceeding with public zones
  only.
- This split hides origin values from the plaintext repo, but Terraform state,
  plan output, and Cloudflare itself can still expose the applied values to
  authorized operators.
