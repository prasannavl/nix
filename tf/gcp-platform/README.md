# OpenTofu GCP Platform

This project manages GCP projects via explicit derived modules under
`tf/modules/gcp/project-*`.

Current scope:

- locate the bootstrap-created `pvl-control` project to discover the
  managed folder
- create and manage the `pvl-dev-tf1` project through
  `tf/modules/gcp/project-dev`
- keep each project's internal layout split by concern (`project.tf`,
  `networks.tf`, `images.tf`, `firewall.tf`, `instances.tf`) similar to the
  original repo shape

Runtime:

- `./scripts/nixbot-deploy.sh --action tf-platform`
- or local wrapper: `./scripts/nixbot-deploy.sh tofu -chdir=tf/gcp-platform plan`

Backend:

- this project uses GCS state
- set `GCP_STATE_BUCKET` before running automated `tf-platform`
- optionally set `GCP_STATE_PREFIX` to override the default
  `gcp-platform/terraform.tfstate`
- optionally set `GCP_BACKEND_IMPERSONATE_SERVICE_ACCOUNT` for backend access

Authentication:

- provider auth relies on normal Google ADC credentials, or on the checked-in
  `impersonate_service_account` variable in `globals.auto.tfvars`

Inputs:

- shared non-secret values live in [`globals.auto.tfvars`](./globals.auto.tfvars)
- dev project naming lives in [`project-dev.auto.tfvars`](./project-dev.auto.tfvars)
- sensitive shared values live under `data/secrets/tf/gcp-platform/`
- add encrypted extra tfvars under `data/secrets/tf/gcp-platform/` if private
  values are introduced later
