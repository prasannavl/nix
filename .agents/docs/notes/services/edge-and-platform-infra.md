# Edge And Platform Infra

## Scope

Canonical infrastructure notes for Cloudflare, GCP Terraform, ingress metadata,
and documentation sanitization rules for infra-facing docs.

## Cloudflare model

- The runnable Cloudflare Terraform projects are:
  - `tf/cloudflare-dns`
  - `tf/cloudflare-platform`
  - `tf/cloudflare-apps`
- Shared module code lives under `tf/modules/cloudflare/`.
- `scripts/nixbot.sh` is the supported execution path for Cloudflare OpenTofu
  runs in local and CI-host contexts.
- DNS, platform resources, Worker source, and runtime credentials each have a
  clear source of truth. Keep public inputs in checked-in tfvars and sensitive
  inputs in encrypted tfvars.
- Import live resources before the first broad apply. Finalize logical keys
  before import, snapshot remote state before import waves, and serialize
  state-changing work against the same backend.

## Tunnel and ingress model

- Tunnel objects belong in Terraform.
- Host runtime wiring belongs in host config unless there is an explicit choice
  to centralize ingress in Cloudflare-managed config.
- For repo-managed services, derive nginx and tunnel ingress from application
  metadata instead of maintaining a second handwritten map.
- `nginxHostNames` plus provider-neutral `tunnels` entries are the durable
  application-facing ingress metadata surface. Use `kind = "cloudflare"` for
  Cloudflare publications and `targetPort` when the tunnel should hit a local
  proxy instead of the exposed service port.

## GCP model

- Keep one-time control-plane bootstrap separate from steady-state platform
  automation.
- Use checked-in public tfvars for non-secret names and IDs, and encrypted
  tfvars for sensitive org, billing, or provider credentials.
- Prefer explicit project modules over opaque legacy defaults.

## State migration and import safety

- Selective Terraform state migration should remain plan-first and write only to
  `.agents/runs/` during planning.
- Generate import and removal steps separately so the target state can be
  verified before source-side deletion.
- Provider-specific import ID quirks and `-var-file` path rules should stay in
  the migration or adoption playbooks rather than being rediscovered ad hoc.

## Documentation sanitization

- Durable infra notes and playbooks should prefer generic placeholders such as
  `<zone>`, `<bucket>`, `<worker>`, and `<ci-host>` unless the literal repo path
  is itself the interface being described.
- Keep live identifiers in config and state, not in general notes.

## Source of truth files

- `tf/cloudflare-dns/**`
- `tf/cloudflare-platform/**`
- `tf/cloudflare-apps/**`
- `tf/gcp-bootstrap/**`
- `tf/gcp-platform/**`
- `tf/modules/cloudflare/**`
- `tf/modules/gcp/**`
- `.agents/docs/playbooks/cloudflare-state-adoption.md`
- `.agents/docs/playbooks/cloudflare-apps.md`
- `.agents/docs/playbooks/cloudflare-email-routing.md`

## Provenance

- This note replaces the earlier dated Cloudflare, GCP, ingress-metadata,
  doc-sanitization, and selective state-migration notes.
