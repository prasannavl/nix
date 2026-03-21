# Terraform Init Failure Propagation

Date: 2026-03-21

- `scripts/nixbot-deploy.sh` runs `run_tf_action` from an `if` condition via
  `run_tf_project_action`.
- In Bash, `set -e` does not abort on failing commands inside a function when
  that function itself is being evaluated by `if`.
- After the multi-provider Terraform refactor, a failing `tofu init` could
  therefore fall through to `plan` or `apply`, which surfaced as a misleading
  follow-on error like `Failed to load ... tfplan... as a plan file`.
- The durable fix is to test `tofu init`, `plan`, and `apply` explicitly inside
  `run_tf_action` and return non-zero immediately on the first failure.
- This keeps the reported Terraform failure aligned with the real root cause,
  such as backend reconfiguration being required.
- The same refactor also accidentally commented `gcp-platform` out of the
  canonical `TF_PROJECT_NAMES` array; restore it so `tf-platform` and `all` keep
  their documented GCP phase coverage.
