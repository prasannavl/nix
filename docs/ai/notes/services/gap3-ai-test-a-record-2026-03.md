# gap3.ai Test A Record 2026-03

## Summary

Added a test apex `A` record for `gap3.ai` in the public-safe OpenTofu tfvars.

## What Changed

- Added `name = "@"`, `type = "A"`, `content = "1.1.1.1"` under
  `tf/zones.auto.tfvars` for the `gap3.ai` zone.

## Notes

- No secret file contents were read.
- This only changes the declared Terraform state; Cloudflare will not change
  until the OpenTofu stack is applied.
