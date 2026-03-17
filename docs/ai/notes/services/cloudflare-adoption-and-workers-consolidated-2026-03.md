# Cloudflare Adoption And Workers Consolidated Notes (2026-03)

## Scope

Canonical March 2026 summary for Cloudflare live export, state-adoption status,
Workers adoption, and the boundary between durable notes, playbooks, and run
artifacts.

## Goal

Adopt the Cloudflare resources already modeled in this repo into OpenTofu state
so future changes come from the repo instead of the dashboard.

## Scope boundaries

- In scope:
  - `tf/cloudflare-platform/`
  - `tf/cloudflare-apps/`
- Out of scope:
  - `tf/cloudflare-dns/` adoption rework
  - Cloudflare surfaces not yet modeled in this repo

## Live export outcome

- The repo has a repeatable export path at `scripts/cloudflare-export.py`.
- March 2026 live export captured the current Cloudflare account into
  repo-managed tfvars plus Worker source/assets.
- Durable exported inventory at that point was:
  - 11 zones
  - 3 Workers
  - 2 R2 buckets
- The exporter writes encrypted Terraform inputs under
  `data/secrets/tf/cloudflare/<category>/` and repo-managed Worker trees under
  `pkgs/cloudflare-workers/`.
- `llmug-hello` briefly used a mirrored assets fallback while investigating the
  live deployment, but the actual local source tree was later copied into
  `pkgs/cloudflare-workers/llmug-hello/` and became the canonical repo source.
- Workers Builds API probing stayed blocked by Cloudflare-side token/API
  behavior, so the durable repo decision was to keep `llmug-hello` locally
  repo-managed here instead of modeling an external Builds integration.

## Adoption status

### Platform

Completed on 2026-03-16:

- Access account-level resources were imported and normalized to a true no-op
  plan.
- R2 buckets `priyasuyash` and `pvl-cloudflare-tf` were imported.
- The `priyasuyash` R2 managed domain was safely adopted through targeted apply
  because provider import support was not available.
- The remaining nine modeled platform resources were imported serially.
- `./scripts/nixbot-deploy.sh --action tf-platform --dry` is now no-op.

Imported platform backlog that mattered:

- R2:
  - `module.cloudflare_platform.cloudflare_r2_bucket.bucket["priyasuyash"]`
  - `module.cloudflare_platform.cloudflare_r2_bucket.bucket["pvl-cloudflare-tf"]`
  - `module.cloudflare_platform.cloudflare_r2_managed_domain.managed_domain["priyasuyash"]`
- DNSSEC:
  - `module.cloudflare_platform.cloudflare_zone_dnssec.dnssec["gap3.ai"]`
  - `module.cloudflare_platform.cloudflare_zone_dnssec.dnssec["llmug.com"]`
- zone settings and certificate packs:
  - `module.cloudflare_platform.cloudflare_zone_setting.general_setting["prasannavl.com/browser_cache_ttl"]`
  - `module.cloudflare_platform.cloudflare_zone_setting.security_setting["llmug.com/always_use_https"]`
  - `module.cloudflare_platform.cloudflare_certificate_pack.certificate_pack["llmug.com/certificate-pack/google-txt-llmug-com"]`
  - `module.cloudflare_platform.cloudflare_certificate_pack.certificate_pack["llmug.com/certificate-pack/google-txt-llmug-com-www-llmug-com"]`
- Email Routing:
  - `module.cloudflare_platform.cloudflare_email_routing_settings.email_routing_settings["p7log.com"]`
  - `module.cloudflare_platform.cloudflare_email_routing_settings.email_routing_settings["prasannavl.com"]`
  - `module.cloudflare_platform.cloudflare_email_routing_rule.email_routing_rule["prasannavl.com/email-rule/0"]`

### Apps / Workers

Completed on 2026-03-16:

- `llmug-hello` Worker resources were imported into `tf/cloudflare-apps`
  remote state.

Imported Worker resources:

- `module.cloudflare_apps.cloudflare_worker.worker["llmug-hello"]`
- `module.cloudflare_apps.cloudflare_worker_version.version["llmug-hello"]`
- `module.cloudflare_apps.cloudflare_workers_deployment.deployment["llmug-hello"]`
- `module.cloudflare_apps.cloudflare_workers_script_subdomain.subdomain["llmug-hello"]`
- `module.cloudflare_apps.cloudflare_workers_custom_domain.domain["llmug-hello/domain/0"]`

Current steady-state decision:

- Worker service adoption is complete, but `tf-apps --dry` is still not no-op
  because immutable version/deployment/custom-domain resources differ from the
  old live wrangler-managed artifact metadata.
- If immediate no-op is required, keep state as-adopted and defer apply.
- If the repo must become active source of truth now, accept one deliberate
  `tf-apps` apply to create the repo-managed version/deployment and converge
  future plans.

## Execution rules that mattered

- Refresh repo-side exports before import when the live account has changed.
- Snapshot remote state before each wave.
- Run state-changing operations serially against the same backend.
- Require a no-op or consciously accepted plan before broad apply.
- Keep playbooks reusable and execution-oriented; keep durable status and
  decisions in notes.

## Execution findings worth keeping

- R2 bucket import IDs use `<account_id>/<bucket_name>/<jurisdiction>`.
- The live R2 buckets in this adoption pass both used `jurisdiction = "default"`.
- `cloudflare_r2_managed_domain` did not support provider import in the pinned
  provider version, so the already-enabled managed domain was adopted through a
  targeted apply after the bucket import.
- Parallel imports against the same remote backend can lose writes; serialize
  them.
- `tofu import` with `-chdir=tf/cloudflare-platform` expects `-var-file` paths
  that are absolute or relative to that project directory.
- The platform adoption pass intentionally excluded Workers and DNS until the
  platform phase was quiet.

## Durable procedure links

- `docs/ai/playbooks/cloudflare-state-adoption.md`
- `docs/ai/playbooks/cloudflare-workers.md`

The run manifests and temporary state snapshots from the March 16 adoption work
have been folded back into this note and cleaned out of `docs/ai/runs/`.

## Superseded notes

- `docs/ai/notes/services/cloudflare-live-export-2026-03.md`
- `docs/ai/notes/services/cloudflare-state-adoption-plan-2026-03.md`
- `docs/ai/notes/services/cloudflare-platform-state-adoption-remaining-2026-03.md`
- `docs/ai/notes/services/cloudflare-workers-state-adoption-2026-03.md`
- `docs/ai/runs/cloudflare-state-adoption-2026-03-16/r2-wave.md`
- `docs/ai/runs/cloudflare-state-adoption-2026-03-16-platform-remaining/platform-remaining-wave.md`
- `docs/ai/runs/cloudflare-state-adoption-2026-03-16-workers/workers-wave.md`
