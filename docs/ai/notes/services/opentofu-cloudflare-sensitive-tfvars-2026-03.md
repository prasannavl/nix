# OpenTofu Cloudflare Sensitive TFVars 2026-03

## Summary

Split Cloudflare DNS Terraform inputs into public-safe and sensitive layers so
origin-bearing or otherwise non-public records can stay encrypted in-repo and
only be decrypted at `--action tf` runtime.

## What Changed

- Added `variable "secret_zones"` alongside `zones` in `tf/variables.tf`.
- Added `variable "secrets"` for reusable encrypted values loaded from a secret
  tfvars file.
- Updated `tf/main.tf` to merge `zones` and `secret_zones` per zone by
  concatenating their `records` lists before creating `cloudflare_dns_record`
  resources.
- Updated `tf/main.tf` so Cloudflare zone lookup covers the union of `zones` and
  `secret_zones`, including zones that only exist in the encrypted layer.
- Relaxed `tf/variables.tf` so `zones` and `secret_zones` use `type = any`,
  while validation still enforces that records include `name`, `type`, and
  either `content` or `data`.
- Registered the encrypted Terraform tfvars files in `data/secrets/default.nix`
  with the same recipients as the existing Cloudflare/R2 Terraform secrets.
- Updated `scripts/nixbot-deploy.sh` so `--action tf` decrypts the encrypted
  tfvars files into its temp dir and passes them to `tofu plan` via `-var-file`
  when present.
- Changed `scripts/nixbot-deploy.sh` to auto-discover all
  `data/secrets/tf/*.tfvars.age` files instead of relying on a hardcoded secret
  tfvars list.
- Generalized `scripts/age-secrets.sh` help text so managed non-`.key` files are
  described correctly.

## Operational Notes

- Public-safe records still live in `tf/zones.auto.tfvars` under `zones = {}`.
- Sensitive records belong in `data/secrets/tf/cloudflare-zones.tfvars.age`
  under `secret_zones = {}`.
- Reusable encrypted values belong in `data/secrets/tf/secrets.tfvars.age` under
  `secrets = {}` and can be referenced as `var.secrets["key"]`.
- All `*.tfvars.age` files under `data/secrets/tf/` are loaded in sorted order
  at `--action tf` runtime; non-matching files in that directory are ignored.
- `scripts/nixbot-deploy.sh --action tf` continues to work without the sensitive
  tfvars secret; it logs that it is proceeding with public zones only.
- This split hides origin values from the plaintext repo, but Terraform state,
  plan output, and Cloudflare itself can still expose the applied values to
  authorized operators.

## Imported Zone Data

- The encrypted zone file now contains authoritative imported records for the
  provided zone export set.
- Imported records preserve exported TTLs, proxied flags, and MX priorities.
- Zones with no managed non-NS/SOA records are still represented explicitly as
  `records = []` so the imported zone set is complete.
- The import source was the provided text exports under
  `/home/pvl/Downloads/cf/`.
- No `.key` files under `data/secrets` were read.

## Canonical Interpretation

Treat this file as the canonical summary for the following superseded March 2026
notes:

- `tf-sensitive-vars-file-split-2026-03.md`
- `opentofu-cloudflare-tf-secrets-dir-autoload-2026-03.md`
- `opentofu-cloudflare-tfvars-type-relaxation-2026-03.md`
- `cloudflare-zone-imports-sensitive-tfvars-2026-03.md`
