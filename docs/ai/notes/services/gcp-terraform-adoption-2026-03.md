# GCP Terraform Adoption

## Summary

- Adopted the non-legacy GCP Terraform from a legacy infrastructure repo into
  this repo's phase-based `tf/` layout.
- Ignored `/legacy/**` from the source repo as requested.
- Split the adopted layout into:
  - `tf/gcp-bootstrap`: manual one-time control-plane bootstrap.
  - `tf/gcp-platform`: automated `*-platform` project for the current dev GCP
    project and its in-project resources.

## Adopted Resources

- Bootstrap:
  - org folder `<org-folder>`
  - control project `<control-project>`
  - control service account `<control-service-account>`
  - shared state bucket `<shared-state-bucket>`
- Platform:
  - project `<dev-project>`
  - enabled project APIs
  - project metadata including SSH key injection
  - VPC `main`
  - subnetwork `main`
  - static address `address-1`
  - firewall rule `allow-22`
  - instance `vm1`

## Structure Decisions

- Replaced the legacy hardcoded defaults module with checked-in `*.auto.tfvars`
  for the current non-secret org/project names and IDs.
- Moved the GCP org and billing IDs out of checked-in tfvars and into encrypted
  Terraform secret files under `data/secrets/tf/gcp/` and
  `data/secrets/tf/gcp-bootstrap/`.
- Added reusable modules under `tf/modules/gcp/bootstrap` and an explicit
  project-derived module under `tf/modules/gcp/project-dev`.
- Kept `gcp-bootstrap` manual rather than teaching `nixbot` a new bootstrap
  phase.
- Added `gcp-platform` to the existing `tf-platform` automation path.
- Refactored `gcp-platform` to use an explicit dev project module and split top
  level inputs into shared globals plus per-project tfvars files under the
  provider/project secret convention.
- Switched `gcp-bootstrap` from local state to the shared R2 backend so
  bootstrap does not depend on GCP state storage already existing.
- Extended `scripts/nixbot.sh` so GCP Terraform uses a GCS backend via
  `GCP_STATE_BUCKET` and optional `GCP_STATE_PREFIX` /
  `GCP_BACKEND_IMPERSONATE_SERVICE_ACCOUNT`, while Cloudflare keeps the R2
  backend path.
- Wired GCP runtime auth into the same repo-managed secret model used for
  Cloudflare: `scripts/nixbot.sh` now decrypts
  `data/secrets/gcp/application-default-credentials.json.age` and exports
  `GOOGLE_APPLICATION_CREDENTIALS` automatically, and it can also auto-load
  `GCP_STATE_BUCKET` plus `GCP_BACKEND_IMPERSONATE_SERVICE_ACCOUNT` from
  encrypted files under `data/secrets/gcp/`.

## Validation Notes

- Local formatting and validation should be run from this repo, not the legacy
  source tree.
- Real plan/apply for GCP still depends on valid Google credentials or
  impersonation access at runtime.
- With the repo-managed JSON auth flow, `gcp-bootstrap` no longer assumes an
  interactive `gcloud auth application-default login`; instead it assumes the
  encrypted credential in
  `data/secrets/gcp/application-default-credentials.json.age` has the required
  org-level permissions.
