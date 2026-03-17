# Cloudflare State Adoption

## Goal

Adopt the existing non-DNS Cloudflare resources that are already represented in
this repo into OpenTofu state so future changes can come from the repo instead
of the dashboard.

## Scope

- `tf/cloudflare-platform/`
  - Zero Trust Access identity providers, groups, policies, applications
  - Zero Trust cloudflared tunnels, remote tunnel configs, and private network routes
  - Workers KV namespaces
  - Email Routing destination addresses
  - R2 buckets and bucket-side features
  - zone DNSSEC
  - zone settings and security settings
  - advanced certificate packs
  - rulesets and page rules
  - cache settings
  - Email Routing zone resources
- `tf/cloudflare-apps/`
  - Workers
  - Worker versions and deployments
  - Workers.dev subdomains
  - Worker cron triggers
  - Worker routes
  - Worker custom domains

## Out Of Scope

- DNS records in `tf/cloudflare-dns/` DNS already has the prior
  state-preservation path and should be left alone in this adoption playbook.
- Cloudflare surfaces not yet modeled in this repo, for example:
  - Access service tokens
  - Access custom pages
  - Access mTLS hostname settings
  - Zero Trust Gateway/device posture
  - Worker secrets that cannot be read back from Cloudflare

## Source Of Truth

- Runnable projects:
  - `tf/cloudflare-platform/`
  - `tf/cloudflare-apps/`
- Shared implementation:
  - `tf/modules/cloudflare/`
- Encrypted inputs:
  - `data/secrets/tf/cloudflare/`
- Export refresh:
  - `scripts/cloudflare-export.py`
  - tunnel export writes `data/secrets/tf/cloudflare/tunnels/account.tfvars.age`
    and intentionally omits unrecoverable runtime tunnel credentials/secrets

## Preconditions

1. Refresh the repo-side Cloudflare inputs from live before importing:
   - full export if multiple surfaces changed
   - targeted export if only one surface changed, for example
     `python scripts/cloudflare-export.py --only access`
   - tunnel-only refresh is available via
     `python scripts/cloudflare-export.py --only tunnels`
2. Review the generated tfvars and normalize names/keys before import.
3. Run:
   - `nix shell nixpkgs#opentofu -c tofu -chdir=tf/cloudflare-platform init`
   - `nix shell nixpkgs#opentofu -c tofu -chdir=tf/cloudflare-apps init`
4. Snapshot the current remote states before each wave:
   - `tofu -chdir=tf/cloudflare-platform state pull > docs/ai/runs/<session>/cloudflare-platform.tfstate.json`
   - `tofu -chdir=tf/cloudflare-apps state pull > docs/ai/runs/<session>/cloudflare-apps.tfstate.json`
5. Do not run `apply` for a phase until its import wave finishes and `plan`
   shows no unintentional creates or destroys.

## Import Waves

### Wave 1: Platform Account-Level

Import these first because other platform resources may reference them.

- Access identity providers
  - address:
    `module.cloudflare_platform.cloudflare_zero_trust_access_identity_provider.identity_provider["<key>"]`
  - import ID: `accounts/<account_id>/<identity_provider_id>`
- Access groups
  - address:
    `module.cloudflare_platform.cloudflare_zero_trust_access_group.group["<key>"]`
- Access reusable policies
  - address:
    `module.cloudflare_platform.cloudflare_zero_trust_access_policy.policy["<key>"]`
  - import ID: `<account_id>/<policy_id>`
- Access applications
  - address:
    `module.cloudflare_platform.cloudflare_zero_trust_access_application.application["<key>"]`
  - import ID: `accounts/<account_id>/<app_id>`
- Workers KV namespaces
  - address:
    `module.cloudflare_platform.cloudflare_workers_kv_namespace.namespace["<key>"]`
- Email Routing destination addresses
  - address:
    `module.cloudflare_platform.cloudflare_email_routing_address.address["<email>"]`
- R2 buckets
  - bucket: `module.cloudflare_platform.cloudflare_r2_bucket.bucket["<bucket>"]`
  - bucket import ID: `<account_id>/<bucket_name>/<jurisdiction>`
  - CORS:
    `module.cloudflare_platform.cloudflare_r2_bucket_cors.cors["<bucket>"]`
  - lifecycle:
    `module.cloudflare_platform.cloudflare_r2_bucket_lifecycle.lifecycle["<bucket>"]`
  - lock:
    `module.cloudflare_platform.cloudflare_r2_bucket_lock.lock["<bucket>"]`
  - managed domain:
    `module.cloudflare_platform.cloudflare_r2_managed_domain.managed_domain["<bucket>"]`
    provider import is not implemented; for an already-enabled managed domain,
    adopt it by importing the bucket first and then running a targeted apply on
    the managed-domain resource, followed by a targeted no-op plan
  - sippy:
    `module.cloudflare_platform.cloudflare_r2_bucket_sippy.sippy["<bucket>"]`
  - custom domain:
    `module.cloudflare_platform.cloudflare_r2_custom_domain.custom_domain["<bucket>/custom-domain/<index>"]`
  - event notification:
    `module.cloudflare_platform.cloudflare_r2_bucket_event_notification.event_notification["<bucket>/event-notification/<index>"]`

- cloudflared tunnels
  - tunnel object:
    `module.cloudflare_platform.cloudflare_zero_trust_tunnel_cloudflared.tunnel["<key>"]`
  - tunnel import ID: `<account_id>/<tunnel_id>`
  - config:
    `module.cloudflare_platform.cloudflare_zero_trust_tunnel_cloudflared_config.config["<key>"]`
  - config import ID: `<account_id>/<tunnel_id>`
  - route:
    `module.cloudflare_platform.cloudflare_zero_trust_tunnel_cloudflared_route.route["<key>/<cidr>"]`
  - route import ID: `<account_id>/<route_id>`
  - exporter emits `config_src`, remote config ingress/origin-request blocks,
    and private network routes. It does not emit `tunnel_secret` or host-side
    credentials because Cloudflare does not expose those values for read-back.
  - local/YAML-managed tunnels should usually import only the tunnel object and
    private network routes. Remote dashboard-managed tunnels can additionally
    import the config resource.

### Wave 2: Platform Zone-Level

Import zone resources after account-level resources are stable.

- DNSSEC
  - `module.cloudflare_platform.cloudflare_zone_dnssec.dnssec["<zone>"]`
- general zone settings
  - `module.cloudflare_platform.cloudflare_zone_setting.general_setting["<zone>/<setting_id>"]`
- security zone settings
  - `module.cloudflare_platform.cloudflare_zone_setting.security_setting["<zone>/<setting_id>"]`
- advanced certificate packs
  - `module.cloudflare_platform.cloudflare_certificate_pack.certificate_pack["<logical-key>"]`
- Universal SSL
  - `module.cloudflare_platform.cloudflare_universal_ssl_setting.universal_ssl["<zone>"]`
- Total TLS
  - `module.cloudflare_platform.cloudflare_total_tls.total_tls["<zone>"]`
- Authenticated Origin Pulls
  - `module.cloudflare_platform.cloudflare_authenticated_origin_pulls_settings.authenticated_origin_pulls["<zone>"]`
- rulesets
  - `module.cloudflare_platform.cloudflare_ruleset.ruleset["<key>"]`
- page rules
  - `module.cloudflare_platform.cloudflare_page_rule.page_rule["<key>"]`
- cache settings
  - `module.cloudflare_platform.cloudflare_tiered_cache.tiered_cache["<zone>"]`
  - `module.cloudflare_platform.cloudflare_regional_tiered_cache.regional_tiered_cache["<zone>"]`
  - `module.cloudflare_platform.cloudflare_zone_cache_reserve.cache_reserve["<zone>"]`
  - `module.cloudflare_platform.cloudflare_zone_cache_variants.cache_variants["<zone>"]`
- Email Routing zone resources
  - settings:
    `module.cloudflare_platform.cloudflare_email_routing_settings.email_routing_settings["<zone>"]`
  - DNS:
    `module.cloudflare_platform.cloudflare_email_routing_dns.email_routing_dns["<zone>"]`
  - explicit rules:
    `module.cloudflare_platform.cloudflare_email_routing_rule.email_routing_rule["<zone>/email-rule/<index>"]`
  - catch-all:
    `module.cloudflare_platform.cloudflare_email_routing_catch_all.email_routing_catch_all["<zone>"]`

### Wave 3: Apps

Import Workers only after platform import is quiet, because worker custom
domains and routes depend on zone/account surfaces already being represented.

- Worker service
  - `module.cloudflare_apps.cloudflare_worker.worker["<worker>"]`
- Worker version
  - `module.cloudflare_apps.cloudflare_worker_version.version["<worker>"]`
- Worker deployment
  - `module.cloudflare_apps.cloudflare_workers_deployment.deployment["<worker>"]`
- Workers.dev subdomain
  - `module.cloudflare_apps.cloudflare_workers_script_subdomain.subdomain["<worker>"]`
- cron triggers
  - `module.cloudflare_apps.cloudflare_workers_cron_trigger.cron_trigger["<worker>"]`
- routes
  - `module.cloudflare_apps.cloudflare_workers_route.route["<worker>/route/<index>"]`
- custom domains
  - `module.cloudflare_apps.cloudflare_workers_custom_domain.domain["<worker>/domain/<index>"]`

## Execution Pattern

For each import wave:

1. Run `tofu -chdir=<project> plan` and record the pre-import create set.
2. Import each declared resource instance into the matching address.
   - Do state-changing operations serially when using the same remote backend.
     Parallel imports can race and lose one of the writes.
3. Run `tofu -chdir=<project> state list` and confirm the new addresses exist.
4. Run `tofu -chdir=<project> plan -refresh-only`.
5. Run `tofu -chdir=<project> plan`.
6. Stop and fix any remaining create/destroy actions before moving to the next
   wave.

If an import was attached to the wrong address:

1. Snapshot state first.
2. Run `tofu -chdir=<project> state rm <address>`.
3. Re-import to the correct address.

## Import Manifest Guidance

Build a session-local manifest under `docs/ai/runs/<session>/` before executing
imports. Each row should capture:

- project
- Terraform address
- repo key
- live Cloudflare identifier used for import
- status
- verification note

This keeps the import pass auditable and makes retries deterministic.

## Verification Gates

- Gate 1: `tf/cloudflare-platform` plan becomes no-op or contains only
  consciously accepted computed drift.
- Gate 2: `tf/cloudflare-apps` plan becomes no-op or contains only consciously
  accepted computed drift.
- Gate 3: `./scripts/nixbot-deploy.sh --action tf-platform --dry` stays clean.
- Gate 4: `./scripts/nixbot-deploy.sh --action tf-apps --dry` stays clean.

## Notes

- The repo now prefers logical tfvar keys where possible. Finalize those keys
  before importing, because changing a `for_each` key later requires a state
  move.
- On March 16, 2026, the first Access import wave confirmed that the current
  repo-managed write token in `data/secrets/cloudflare/api-token.key.age`
  initially lacked Access endpoint permission, but that scope was later added
  and the Access slice now plans cleanly with the normal runtime token.
- The exporter captures current configuration shape, but import IDs are still
  provider-resource specific and should be sourced from the provider docs or
  from a confirmed successful trial during execution.
- On March 16, 2026, the Access slice was normalized to a true no-op plan and
  then the R2 slice was adopted:
  - buckets: two modeled R2 bucket instances
  - managed domain: one already-enabled bucket-side managed domain
- Email Routing destination verification remains manual even after import.
