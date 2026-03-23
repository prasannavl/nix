# gap3.ai Hello Site

## Goal

Add a repo-managed Cloudflare app for `gap3.ai` with a minimal static hello page
and a Terraform-managed custom domain.

## Decisions

- App name: `gap3-ai`
- Delivery model: assets-only Cloudflare Worker under `pkgs/cloudflare-apps/`
- Domain wiring: Terraform `custom_domains` entry for apex `gap3.ai`
- Content scope: intentionally minimal single-page site with `Hello`

## Files

- `pkgs/cloudflare-apps/gap3-ai/`: app source, build helper, and Wrangler config
- `tf/cloudflare-apps/workers.auto.tfvars`: public-safe Worker definition

## Follow-Up

- Apply `nixbot tf-apps` to provision the Worker and attach the custom domain in
  the live Cloudflare account.
