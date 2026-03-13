# OpenTofu Cloudflare DNS

This directory is the source of truth for Cloudflare-managed DNS.

## Scope

This stack manages the Cloudflare DNS zones declared in `zones.auto.tfvars` and,
when needed, the encrypted
`data/secrets/cloudflare/zones-sensitive.auto.tfvars.age`. Keep concrete domain
names in config and secrets, not in documentation.

## Layout

- `versions.tf`: OpenTofu and provider constraints.
- `backend.tf`: remote state backend declaration.
- `providers.tf`: Cloudflare provider configuration.
- `main.tf`: zone lookups and DNS record resources.
- `zones.auto.tfvars`: authoritative public-safe record definitions.
- `data/secrets/cloudflare/zones-sensitive.auto.tfvars.age`: authoritative
  encrypted record definitions loaded only for
  `scripts/nixbot-deploy.sh
  --action tf`.

## Auth

Set the Cloudflare API token in the environment:

```bash
export CLOUDFLARE_API_TOKEN=...
```

The token should have DNS edit access for the managed zones.

On `pvl-x2`, `scripts/nixbot-deploy.sh --action tf` can load the required
Cloudflare, R2, and sensitive DNS values from repo-managed age secret files
instead of exported shell variables:

- `data/secrets/cloudflare/api-token.key.age`
- `data/secrets/cloudflare/r2-account-id.key.age`
- `data/secrets/cloudflare/r2-state-bucket.key.age`
- `data/secrets/cloudflare/r2-access-key-id.key.age`
- `data/secrets/cloudflare/r2-secret-access-key.key.age`
- `data/secrets/cloudflare/zones-sensitive.auto.tfvars.age`

Those secrets stay in the repo and are decrypted on demand by
`scripts/nixbot-deploy.sh` using the bastion's existing age identity.

## Remote State

The configuration uses Cloudflare R2 for remote state via the `s3` backend. R2
is S3-compatible, so OpenTofu can talk to it through normal backend config.

Example init:

```bash
tofu -chdir=tf init \
  -backend-config='bucket=REPLACE_ME' \
  -backend-config='key=cloudflare-dns/terraform.tfstate' \
  -backend-config='region=auto' \
  -backend-config='endpoint=https://ACCOUNT_ID.r2.cloudflarestorage.com' \
  -backend-config='access_key=REPLACE_ME' \
  -backend-config='secret_key=REPLACE_ME' \
  -backend-config='skip_credentials_validation=true' \
  -backend-config='skip_region_validation=true' \
  -backend-config='skip_requesting_account_id=true' \
  -backend-config='use_path_style=true'
```

## Workflow

1. Populate `zones.auto.tfvars` with public-safe records only.
2. Put any origin-bearing or otherwise sensitive records in
   `data/secrets/cloudflare/zones-sensitive.auto.tfvars.age` using the
   `secret_zones` variable.
3. Put reusable encrypted values in that same secret tfvars file under
   `secrets = {}` and reference them from Terraform as `var.secrets["name"]`.
4. Import existing Cloudflare DNS records into state before the first apply if
   those zones already contain records you want OpenTofu to own.
5. Run `tofu -chdir=tf plan`.
6. Run `tofu -chdir=tf apply`.

Without importing pre-existing records, OpenTofu will only manage the resources
declared here and will not automatically adopt or delete unrelated existing
records in Cloudflare.

## Execution

Run locally:

```bash
CLOUDFLARE_API_TOKEN=... \
R2_ACCOUNT_ID=... \
R2_STATE_BUCKET=... \
R2_ACCESS_KEY_ID=... \
R2_SECRET_ACCESS_KEY=... \
./scripts/nixbot-deploy.sh --action tf
```

The deploy script always enters a `nix shell` runtime using this repo's flake
inputs, so `tofu` does not need to be preinstalled separately on the machine
running it. When the secret tfvars file exists, the script decrypts it into a
temp file and passes it via `-var-file` for that run only.

Dry-run:

```bash
CLOUDFLARE_API_TOKEN=... \
R2_ACCOUNT_ID=... \
R2_STATE_BUCKET=... \
R2_ACCESS_KEY_ID=... \
R2_SECRET_ACCESS_KEY=... \
./scripts/nixbot-deploy.sh --action tf --dry
```

From GitHub Actions, use the existing `nixbot` workflow with `workflow_dispatch`
and select `action=tf`. That executes through the bastion trigger path, so the
required Cloudflare and R2 credentials must either be present in the bastion
environment or committed as the encrypted repo secret files above.
