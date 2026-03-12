# OpenTofu Cloudflare DNS 2026-03

## Summary

Replaced the earlier experimental Nix-based Cloudflare DNS reconciliation idea
with a dedicated root `tf/` OpenTofu stack using the official
`cloudflare/cloudflare` provider.

## What Changed

- Added `tf/` with OpenTofu configuration for the repo's managed Cloudflare DNS
  zones.
- Declared Cloudflare DNS records via `cloudflare_dns_record`.
- Added `tf/zones.auto.tfvars` as the authoritative per-zone record definition
  file.
- Extended `scripts/nixbot-deploy.sh` with `--action tf` so OpenTofu can run:
  - locally,
  - through the bastion trigger,
  - through the existing `.github/workflows/nixbot.yaml` workflow.

## Operational Notes

- `--action tf` expects the Cloudflare token and R2 credentials in the runtime
  environment of the machine executing OpenTofu.
- The existing GitHub `nixbot` workflow now accepts `action=tf` for manual
  dispatch, but execution still happens on the bastion side through
  `--bastion-trigger`.
- Existing Cloudflare records must be imported into OpenTofu state before the
  first apply if they should remain managed.
- No secret file contents were read during this task.
