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
Run it once with user credentials that can create folders, projects, IAM
bindings, and buckets at the organization level.

Usage:

- `cd tf/gcp-bootstrap`
- `tofu init` with the same R2 backend settings used by the other Terraform
  projects, or use the wrapper:
  `./scripts/nixbot-deploy.sh tofu -chdir=tf/gcp-bootstrap init`
- `tofu plan -var-file=../../data/secrets/tf/gcp/globals.tfvars -var-file=../../data/secrets/tf/gcp-bootstrap/globals.tfvars`
- `tofu apply -var-file=../../data/secrets/tf/gcp/globals.tfvars -var-file=../../data/secrets/tf/gcp-bootstrap/globals.tfvars`
- or use the wrapper so encrypted tfvars are auto-loaded:
  `./scripts/nixbot-deploy.sh tofu -chdir=tf/gcp-bootstrap plan`

Notes:

- State uses the shared R2 Terraform backend with the default key
  `gcp-bootstrap/terraform.tfstate`.
- The checked-in `bootstrap.auto.tfvars` carries only non-secret naming and
  bucket-location values. Sensitive IDs now live under `data/secrets/tf/gcp/`
  and `data/secrets/tf/gcp-bootstrap/`.
