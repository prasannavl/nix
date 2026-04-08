# OpenTofu GCP Platform

GCP platform phase for managed projects.

## Scope

- locate the bootstrap-created `pvl-control` project to discover the managed
  folder
- create and manage the `pvl-dev-tf1` project through
  `tf/modules/gcp/project-dev`
- keep each project's internal layout split by concern (`project.tf`,
  `networks.tf`, `images.tf`, `firewall.tf`, `instances.tf`) similar to the
  original repo shape

## Runtime

- `nixbot tf-platform`
- `nixbot tofu -chdir=tf/gcp-platform plan`

## Backend

- uses GCS state
- `nixbot` auto-loads `GCP_STATE_BUCKET` when present
- `GCP_STATE_PREFIX` can override the default key
- `nixbot` also auto-loads backend impersonation config when present

## Authentication

- provider auth comes from the repo-managed encrypted Google service-account
  JSON
- `nixbot` decrypts it and exports `GOOGLE_APPLICATION_CREDENTIALS`
- the provider may also impersonate the configured service account from tfvars

## Inputs

- non-secret shared values: [`globals.auto.tfvars`](./globals.auto.tfvars)
- dev project naming: [`project-dev.auto.tfvars`](./project-dev.auto.tfvars)
- provider secrets: `data/secrets/tf/gcp/`
- project secrets: `data/secrets/tf/gcp-platform/`
