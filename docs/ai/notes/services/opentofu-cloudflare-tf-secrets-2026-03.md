# OpenTofu Cloudflare TF Secrets 2026-03

## Summary

Moved the Cloudflare DNS OpenTofu runtime credentials onto the repo age-secrets
path so bastion-triggered `--action tf` no longer depends on manually exported
shell variables on the bastion host.

## What Changed

- Added these managed secret entries under `data/secrets/cloudflare/`:
  - `api-token.key.age`
  - `r2-account-id.key.age`
  - `r2-state-bucket.key.age`
  - `r2-access-key-id.key.age`
  - `r2-secret-access-key.key.age`
- Updated `scripts/nixbot-deploy.sh` so `run_tf_action` loads any missing
  Terraform env vars by decrypting those repo `.age` files on demand before
  validating required inputs.
- Updated repo docs and `tf/README.md` to document the secret-backed path.

## Operational Notes

- Explicit environment variables still win over secret files.
- Local non-bastion runs can keep using direct env exports.
- Secrets are not materialized to permanent files on the bastion as part of the
  Terraform flow.
- No secret file contents were read during this task.
