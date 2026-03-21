# Cloudflare OpenTofu Consolidated Notes (2026-03)

## Scope

Canonical March 2026 summary for this repo's Cloudflare OpenTofu layout, modeled
surfaces, export/input strategy, and source-of-truth rules.

## Runnable layout

- Runnable Cloudflare projects are split by phase:
  - `tf/cloudflare-dns/`
  - `tf/cloudflare-platform/`
  - `tf/cloudflare-apps/`
- Shared implementation lives in `tf/modules/cloudflare/`.
- `scripts/nixbot.sh` is the supported execution path for local,
  bastion-triggered, and CI-driven Cloudflare OpenTofu runs.
- Aggregate `--action tf` remains the Terraform-only sequence: DNS, platform,
  then apps.

## Source of truth

- DNS records live in the DNS project plus encrypted/public tfvars under
  `data/secrets/tf/cloudflare/`, `data/secrets/tf/cloudflare-dns/`, and the
  phase-local auto-tfvars files.
- Platform resources live in `tf/cloudflare-platform/` and the matching
  encrypted/public inputs under `data/secrets/tf/cloudflare/` and
  `data/secrets/tf/cloudflare-platform/`.
- Workers/apps source lives under `pkgs/cloudflare-apps/<app>/`.
- Workers/platform Terraform inputs live in:
  - `tf/cloudflare-platform/*.auto.tfvars`
  - `tf/cloudflare-apps/*.auto.tfvars`
  - `data/secrets/tf/cloudflare/**`
  - `data/secrets/tf/cloudflare-platform/**`
  - `data/secrets/tf/cloudflare-apps/**`
- Runtime credentials come from environment variables when explicitly provided,
  otherwise from repo-managed age secrets under `data/secrets/cloudflare/`.

## Input and secret model

- Public-safe inputs stay in project-local `*.auto.tfvars` files.
- Provider-wide encrypted tfvars load from `data/secrets/tf/<provider>/` before
  project/root-specific encrypted tfvars under `data/secrets/tf/<project>/`.
- DNS zone declarations use a plaintext `zones` map for public-safe records and
  explicit encrypted top-level zone groups for sensitive records, so active,
  staged, archived, and inactive zone sets can be reclassified without changing
  runtime loading behavior.
- Sensitive inputs stay encrypted under
  `data/secrets/tf/cloudflare/**.tfvars.age`,
  `data/secrets/tf/cloudflare-dns/**.tfvars.age`,
  `data/secrets/tf/cloudflare-platform/**.tfvars.age`, and
  `data/secrets/tf/cloudflare-apps/**.tfvars.age`.
- `scripts/nixbot.sh` auto-discovers encrypted tfvars, decrypts them into its
  temp workspace, and passes them to OpenTofu in sorted path order.
- The encrypted tfvars loader is generic: all matching
  `data/secrets/tf/**/*.tfvars.age` files are eligible input, and missing
  sensitive Cloudflare tfvars should degrade to a public-only run rather than
  aborting the Terraform phase.
- Reusable encrypted scalar values belong in provider-level tfvars such as
  `data/secrets/tf/cloudflare/globals.tfvars.age` under `secrets = {}` so
  Terraform input files can reference them without duplicating plaintext values.
- The Cloudflare runtime secret path is repo-managed and covers the API token,
  R2 account information, and state-bucket credentials.
- Explicit environment variables still override secret-file loading.

## Modeled Cloudflare surface

- DNS:
  - `cloudflare_dns_record`
- Platform/account-level:
  - Zero Trust Access identity providers, groups, policies, applications
  - Workers KV namespaces
  - Email Routing destination addresses
  - R2 buckets and bucket-side features
- Platform/zone-level:
  - DNSSEC
  - zone settings and security settings
  - rulesets and page rules
  - tiered cache and related cache controls
  - advanced certificate packs
  - Email Routing zone resources
- Apps:
  - Workers services
  - Worker versions and deployments
  - Workers.dev subdomains
  - routes, cron triggers, and custom domains
- Tunnel adoption should land in `tf/cloudflare-platform/` with stable Terraform
  keys chosen before import. The safest initial ownership boundary is
  tunnel-object adoption first, keeping ingress config host-managed unless there
  is an explicit decision to move that config into Terraform.

## Export and normalization rules

- `scripts/archive/cloudflare-export.py` is the durable export entrypoint.
- Exported input maps prefer logical keys over Cloudflare-assigned IDs when
  those IDs are not required as authoring handles.
- Access exports now use logical keys and rewrite their internal references to
  match.
- Advanced certificate packs also use logical keys rather than certificate-pack
  IDs.
- HTTPS and SSL behavior should be modeled through zone settings and rulesets;
  page rules are reserved for legacy forwarding cases that still exist live.

## Workers ownership model

- Durable Worker infrastructure ownership belongs in the repo, not the
  dashboard.
- Worker/app source should live under `pkgs/cloudflare-apps/<app>/` and be
  deployed through the same Nix/OpenTofu flow as the rest of the stack.
- Sensitive Worker bindings belong in encrypted tfvars, not dashboard-only
  configuration.
- Existing dashboard-managed Workers, routes, and custom domains must be
  imported before first apply.
- The primary repo-managed Worker is intentionally treated as a local repo-owned
  Worker instead of trying to model Cloudflare Workers Builds as the source of
  truth.

## Operational rules

- Import existing live resources before first apply if the repo should own them.
- Finalize logical keys before import; later key changes require state moves.
- State-changing operations against the same remote backend must be serialized.
- Workers version/deployment resources are expected to differ from old
  wrangler-managed metadata until a one-time repo-managed convergence apply is
  accepted.
- One-off verification records or other narrow test declarations do not need
  standalone durable notes unless they establish a reusable modeling rule.

## Related playbooks

- `docs/ai/playbooks/cloudflare-state-adoption.md`
- `docs/ai/playbooks/cloudflare-apps.md`
- `docs/ai/playbooks/cloudflare-email-routing.md`

## Superseded notes

- `docs/ai/notes/services/opentofu-cloudflare-dns-2026-03.md`
- `docs/ai/notes/services/opentofu-cloudflare-workers-2026-03.md`
- `docs/ai/notes/services/opentofu-cloudflare-platform-surface-2026-03.md`
- `docs/ai/notes/services/opentofu-cloudflare-module-relocation-2026-03.md`
- `docs/ai/notes/services/opentofu-cloudflare-tf-secrets-2026-03.md`
- `docs/ai/notes/services/opentofu-cloudflare-sensitive-tfvars-2026-03.md`
- `docs/ai/notes/services/public-dns-test-a-record-2026-03.md`
- `docs/ai/notes/services/cloudflare-access-platform-export-2026-03.md`
- `docs/ai/notes/services/cloudflare-logical-tfvar-keys-2026-03.md`
- `docs/ai/notes/services/cloudflare-ssl-and-https-surface-2026-03.md`
- `docs/ai/notes/services/cloudflare-workers-repo-management-feasibility-2026-03.md`
