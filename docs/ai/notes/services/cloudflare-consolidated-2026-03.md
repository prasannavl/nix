# Cloudflare Consolidated Notes (2026-03)

## Scope

Canonical March 2026 reference for Cloudflare OpenTofu layout, state adoption
status, Workers ownership, tunnel adoption plan, and operational lessons.

---

## OpenTofu layout

### Runnable projects

| Project  | Path                      |
| -------- | ------------------------- |
| DNS      | `tf/cloudflare-dns/`      |
| Platform | `tf/cloudflare-platform/` |
| Apps     | `tf/cloudflare-apps/`     |

- Shared module code lives in `tf/modules/cloudflare/`.
- `scripts/nixbot.sh` is the supported execution path for all Cloudflare
  OpenTofu runs (local, bastion, CI).
- Aggregate `--action tf` runs the phases in order: DNS, platform, apps.

### Source-of-truth rules

- DNS records: DNS project + encrypted/public tfvars.
- Platform resources: `tf/cloudflare-platform/` + matching encrypted/public
  inputs.
- Workers/apps source: `pkgs/cloudflare-apps/<app>/`.
- Runtime credentials: environment variables override; otherwise repo-managed
  age secrets under `data/secrets/cloudflare/`.

### Input and secret model

- Public-safe inputs stay in project-local `*.auto.tfvars` files.
- Provider-wide encrypted tfvars load from `data/secrets/tf/<provider>/` before
  project-specific encrypted tfvars under `data/secrets/tf/<project>/`.
- `scripts/nixbot.sh` auto-discovers `data/secrets/tf/**/*.tfvars.age`, decrypts
  into its temp workspace, and passes them to OpenTofu in sorted path order.
- Missing sensitive tfvars degrade to a public-only run rather than aborting.
- Reusable encrypted scalars belong in provider-level tfvars (e.g.
  `data/secrets/tf/cloudflare/globals.tfvars.age` under `secrets = {}`) to avoid
  duplicating plaintext values.

---

## Live export

- Repeatable export script: `scripts/archive/cloudflare-export.py`.
- March 2026 export captured 11 zones, 3 Workers, 2 R2 buckets.
- Exporter writes encrypted Terraform inputs under
  `data/secrets/tf/cloudflare/<category>/` and Worker source trees under
  `pkgs/cloudflare-apps/`.
- Exported input maps prefer logical keys over Cloudflare-assigned IDs.
- Access exports use logical keys with rewritten internal references.

---

## Modeled Cloudflare surface

- **DNS:** `cloudflare_dns_record`
- **Platform / account-level:** Zero Trust Access (identity providers, groups,
  policies, applications), Workers KV namespaces, Email Routing destination
  addresses, R2 buckets and bucket-side features.
- **Platform / zone-level:** DNSSEC, zone settings, security settings, rulesets,
  page rules (legacy forwarding only), tiered cache, advanced certificate packs,
  Email Routing zone resources.
- **Apps:** Workers services, versions, deployments, workers.dev subdomains,
  routes, cron triggers, custom domains.
- **Tunnels (planned):** tunnel objects belong in `tf/cloudflare-platform/`; see
  tunnel adoption plan below.

---

## State adoption status

### Platform -- completed 2026-03-16

All platform resources imported and normalized to a no-op plan:

- R2 buckets (2) and one R2 managed domain (adopted via targeted apply because
  provider import was unavailable).
- DNSSEC, zone settings, security settings, certificate packs.
- Email Routing settings and rules.
- Access account-level resources.

`./scripts/nixbot.sh --action tf-platform --dry` is no-op.

### Apps / Workers -- completed 2026-03-16

One repo-managed Worker fully imported (service, version, deployment, subdomain,
custom domain).

Steady-state note: `tf-apps --dry` is not yet no-op because immutable
version/deployment resources differ from old wrangler-managed metadata. A
one-time repo-managed convergence apply is needed to make the repo the active
source of truth.

---

## Workers ownership model

- Durable Worker infrastructure ownership belongs in the repo, not the
  dashboard.
- Worker source lives under `pkgs/cloudflare-apps/<app>/` and deploys through
  the Nix/OpenTofu flow.
- Sensitive Worker bindings belong in encrypted tfvars.
- The primary repo-managed Worker is treated as a local repo-owned Worker;
  Cloudflare Workers Builds integration was investigated but stayed blocked by
  token/API limitations.

---

## Tunnel adoption plan

### Ownership boundary decision (open)

Two options before import:

1. **Host-managed config** -- Terraform owns the tunnel object; NixOS host
   config owns ingress/default service via `services.cloudflared.tunnels`. Set
   `config_src = "local"` in Terraform.
2. **Cloudflare-managed config** -- Terraform owns both tunnel object and
   ingress config. Host config reduces to credentials/runtime only.

Recommendation: import tunnel objects first (option 1), then centralize ingress
only if explicitly decided.

### Target layout

- Public inputs: `tf/cloudflare-platform/tunnels.auto.tfvars` with stable keys
  (e.g. `<host>-main`).
- Encrypted inputs (only if tunnel secret must be in TF):
  `data/secrets/tf/cloudflare/tunnels/tunnels.tfvars.age`.
- Host runtime credentials: already declared in
  `data/secrets/cloudflare/tunnels/` via agenix.

### Import sequence

1. Inventory live tunnels manually (no exporter support yet). Per tunnel:
   Terraform key, UUID, display name, config source, ingress source, private
   routes, credential file, connector host(s).
2. Decide tunnel topology before import -- do not import under a temporary key
   if the desired state is different.
3. Author repo inputs with final stable keys.
4. Snapshot remote state, then import serially:
   - Tunnel object: import ID `<account_id>/<tunnel_id>`
   - Tunnel config (if applicable): same import ID
   - Private routes (if any): `<account_id>/<route_id>`
5. Verify: `plan -refresh-only`, then full plan, then
   `./scripts/nixbot.sh --action tf-platform --dry`.
6. After stable adoption, replace placeholder UUIDs in host Nix config and stage
   real credential JSONs.

### Open questions

- One shared tunnel or one tunnel per host?
- Host-managed or Cloudflare-managed ingress?
- Any live private network routes needing adoption?
- Is the agenix credentials JSON sufficient, or must the tunnel secret also live
  in Terraform state?

---

## Operational rules

- Import existing live resources before first apply.
- Finalize logical keys before import; later key changes require state moves.
- Serialize state-changing operations against the same remote backend (parallel
  imports can lose writes).
- Snapshot remote state before each import wave.
- `tofu import` with `-chdir=` expects `-var-file` paths relative to that
  project directory.
- R2 bucket import IDs use `<account_id>/<bucket_name>/<jurisdiction>`.
- `cloudflare_r2_managed_domain` did not support provider import in the pinned
  provider version; adopt via targeted apply.
- Require a no-op or consciously accepted plan before broad apply.

---

## Lesson: Worker archive path fix

When repo layout changes move Worker source directories, update both the
public/plaintext tfvars authoring file and its encrypted `.age` counterpart.
`tf/modules/cloudflare/workers.tf` resolves `modules[*].content_file` relative
to `path.root` and hashes those files during planning, so stale paths fail
before apply. Fresh worktree checkouts expose this immediately because they only
contain the current layout.

---

## Related playbooks

- `docs/ai/playbooks/cloudflare-state-adoption.md`
- `docs/ai/playbooks/cloudflare-apps.md`
- `docs/ai/playbooks/cloudflare-email-routing.md`

## Superseded notes

- `cloudflare-adoption-and-workers-consolidated-2026-03.md`
- `cloudflare-opentofu-consolidated-2026-03.md`
- `cloudflare-tunnel-state-adoption-plan-2026-03.md`
- `cloudflare-workers-archive-path-fix-2026-03.md`
- `cloudflare-live-export-2026-03.md`
- `cloudflare-state-adoption-plan-2026-03.md`
- `cloudflare-platform-state-adoption-remaining-2026-03.md`
- `cloudflare-workers-state-adoption-2026-03.md`
- `opentofu-cloudflare-dns-2026-03.md`
- `opentofu-cloudflare-workers-2026-03.md`
- `opentofu-cloudflare-platform-surface-2026-03.md`
- `opentofu-cloudflare-module-relocation-2026-03.md`
- `opentofu-cloudflare-tf-secrets-2026-03.md`
- `opentofu-cloudflare-sensitive-tfvars-2026-03.md`
- `public-dns-test-a-record-2026-03.md`
- `cloudflare-access-platform-export-2026-03.md`
- `cloudflare-logical-tfvar-keys-2026-03.md`
- `cloudflare-ssl-and-https-surface-2026-03.md`
- `cloudflare-workers-repo-management-feasibility-2026-03.md`
