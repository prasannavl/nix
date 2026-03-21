# OpenTofu GCP Platform

This project manages GCP projects via explicit derived modules under
`tf/modules/gcp/project-*`.

Current scope:

- locate the bootstrap-created `pvl-control` project to discover the managed
  folder
- create and manage the `pvl-dev-tf1` project through
  `tf/modules/gcp/project-dev`
- keep each project's internal layout split by concern (`project.tf`,
  `networks.tf`, `images.tf`, `firewall.tf`, `instances.tf`) similar to the
  original repo shape

Runtime:

- `./scripts/nixbot-deploy.sh --action tf-platform`
- or local wrapper:
  `./scripts/nixbot-deploy.sh tofu -chdir=tf/gcp-platform plan`

Backend:

- this project uses GCS state
- `scripts/nixbot-deploy.sh` auto-loads `GCP_STATE_BUCKET` from
  `data/secrets/gcp/state-bucket.key.age` when present
- optionally set `GCP_STATE_PREFIX` to override the default
  `gcp-platform/terraform.tfstate`
- `scripts/nixbot-deploy.sh` auto-loads
  `GCP_BACKEND_IMPERSONATE_SERVICE_ACCOUNT` from
  `data/secrets/gcp/backend-impersonate-service-account.key.age` when present

Authentication:

- provider auth is expected to come from the repo-managed encrypted Google
  service-account JSON at
  `data/secrets/gcp/application-default-credentials.json.age`
- `scripts/nixbot-deploy.sh` decrypts that file at runtime and exports
  `GOOGLE_APPLICATION_CREDENTIALS` automatically
- the Google provider then uses that credential as the base identity and may
  still impersonate the checked-in `impersonate_service_account` value from
  `globals.auto.tfvars`

Inputs:

- shared non-secret values live in
  [`globals.auto.tfvars`](./globals.auto.tfvars)
- dev project naming lives in
  [`project-dev.auto.tfvars`](./project-dev.auto.tfvars)
- sensitive provider-wide values live under `data/secrets/tf/gcp/`
- sensitive project-specific values live under `data/secrets/tf/gcp-platform/`
- add encrypted extra tfvars under `data/secrets/tf/gcp-platform/` if private
  values are introduced later
