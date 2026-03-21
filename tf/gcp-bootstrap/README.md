# OpenTofu GCP Bootstrap

Manual bootstrap for the shared GCP control plane.

Scope:

- create the `pvl` root folder under the organization
- create the `pvl-control` project
- enable core APIs required for follow-on Terraform
- create the `tf-control-sa` service account and grant its org/folder/project
  IAM
- create the shared `pvl-control-state` GCS bucket

This project is intentionally separate from the automated `*-platform` phase.
Run it once with credentials that can create folders, projects, IAM bindings,
and buckets at the organization level. In this repo, those credentials are now
expected to come from the encrypted Google service-account JSON loaded by
`scripts/nixbot.sh`.

Usage:

- `cd tf/gcp-bootstrap`
- `tofu init` with the same R2 backend settings used by the other Terraform
  projects, or use the wrapper:
  `./scripts/nixbot.sh tofu -chdir=tf/gcp-bootstrap init`
- `tofu plan -var-file=../../data/secrets/tf/gcp/globals.tfvars -var-file=../../data/secrets/tf/gcp-bootstrap/globals.tfvars`
- `tofu apply -var-file=../../data/secrets/tf/gcp/globals.tfvars -var-file=../../data/secrets/tf/gcp-bootstrap/globals.tfvars`
- or use the wrapper so encrypted tfvars are auto-loaded:
  `./scripts/nixbot.sh tofu -chdir=tf/gcp-bootstrap plan`

Notes:

- State uses the shared R2 Terraform backend with the default key
  `gcp-bootstrap/terraform.tfstate`.
- The checked-in `bootstrap.auto.tfvars` carries only non-secret naming and
  bucket-location values. Sensitive IDs now live under `data/secrets/tf/gcp/`
  and `data/secrets/tf/gcp-bootstrap/`.
- Provider auth is expected to come from the repo-managed encrypted Google
  service-account JSON at
  `data/secrets/gcp/application-default-credentials.json.age`.
- `scripts/nixbot.sh` decrypts that file at runtime and exports
  `GOOGLE_APPLICATION_CREDENTIALS` automatically for bootstrap runs too.
- That credential still needs organization-level permissions sufficient for the
  bootstrap scope above.
