# Cloudflare Tunnel State Adoption Plan (2026-03)

## Goal

Adopt the current live Cloudflare Tunnel resources into `tf/cloudflare-platform`
so the repo becomes the durable source of truth for tunnel ownership going
forward.

## Verified current state

- Tunnel resources are already modeled in `tf/modules/cloudflare/tunnels.tf` and
  exposed through `tf/cloudflare-platform/`.
- `tf/cloudflare-platform/README.md` already documents import addresses and ID
  formats for:
  - `cloudflare_zero_trust_tunnel_cloudflared`
  - `cloudflare_zero_trust_tunnel_cloudflared_config`
  - `cloudflare_zero_trust_tunnel_cloudflared_route`
- Public-safe tunnel inputs now live in:
  - `tf/cloudflare-platform/tunnels.auto.tfvars`
- Encrypted tunnel exporter output now lives in:
  - `data/secrets/tf/cloudflare/tunnels/account.tfvars.age`
- `scripts/cloudflare-export.py` currently:
  - resolves credentials from `data/secrets/cloudflare/api-token-readall.key.age`
    first, then falls back to `api-token.key.age`
  - resolves the Cloudflare account ID from
    `data/secrets/cloudflare/r2-account-id.key.age`
  - supports `--only all`, `--only access`, and `--only tunnels`
  - exports Access, zones, Workers, R2, KV, email routing, and related
    platform/app inputs into `data/secrets/tf/cloudflare/**`
  - now fetches and normalizes tunnel inventory, remote tunnel config, and
    private network routes into tunnel tfvars
  - still does **not** export unrecoverable host credential JSONs or preserved
    tunnel secrets
- Host runtime secret paths are already reserved in `data/secrets/default.nix`
  for:
  - `data/secrets/cloudflare/tunnels/<bastion-host>-main.credentials.json.age`
  - `data/secrets/cloudflare/tunnels/<service-host>-main.credentials.json.age`
- The host Cloudflare tunnel Nix files currently use placeholder UUIDs and
  example ingress hostnames, so they should not be treated as live source of
  truth yet.

## Main decision to make before import

Choose the ownership boundary for tunnel configuration:

1. **Host-managed tunnel config**
   - Terraform imports and owns the tunnel object itself.
   - NixOS host config continues to own ingress/default service locally through
     `services.cloudflared.tunnels`.
   - In Terraform, set `config_src = "local"` for imported tunnels and do not
     import `tunnel_configs` unless there is a real Cloudflare-managed config to
     preserve.
2. **Cloudflare-managed tunnel config**
   - Terraform imports and owns both the tunnel object and the
     Cloudflare-side tunnel config.
   - Host config should be reduced to credentials/runtime only and should stop
     being the authoring location for ingress rules.
   - This matches the module default of `config_src = "cloudflare"`.

Given the current repo shape, the safer first adoption path is to import the
**tunnel objects first**, then import Cloudflare-managed config only if we
explicitly decide to centralize ingress in Terraform.

## Export-script implications

The export workflow is now part of the repeatable tunnel adoption path.

What the exporter can help with today:

- confirming the Cloudflare account ID and token wiring used by repo automation
- refreshing surrounding Access / zone / app state so tunnel adoption does not
  happen against stale adjacent data
- preserving the repo's established encrypted tfvars write pattern under
  `data/secrets/tf/cloudflare/**`
- generating tunnel inventory, remote-config input shape, and private-route
  input shape for the modeled tunnel surface

What it cannot help with today:

- discovering or packaging host credential JSONs
- exporting unrecoverable preserved tunnel secrets

Operational consequence:

- the exporter removes most of the manual inventory work for future tunnel
  adoption waves
- host credential staging and any final import manifest still need a small,
  explicit run-local execution record

## Recommended target layout

### Public-safe Terraform inputs

Create a new tracked file:

- `tf/cloudflare-platform/tunnels.auto.tfvars`

Suggested contents:

- `tunnels`
  - stable Terraform keys such as `<bastion-host>-main` or
    `<service-host>-main`
  - `name`
  - optional `config_src`
- `tunnel_configs`
  - only if choosing Cloudflare-managed config
- `tunnel_routes`
  - only for private network routes actually used live

### Encrypted Terraform inputs

Only add a new encrypted tfvars file if a tunnel attribute must remain secret in
Terraform input form, for example a preserved tunnel `secret`:

- `data/secrets/tf/cloudflare/tunnels/tunnels.tfvars.age`

Prefer not to model the tunnel secret unless required for the chosen ownership
mode; the runtime credentials JSON already belongs in agenix and does not need
to be duplicated into Terraform unless there is a specific reason.

### Host runtime credentials

Populate the already-declared agenix files with the real live credential JSONs:

- `data/secrets/cloudflare/tunnels/<bastion-host>-main.credentials.json.age`
- `data/secrets/cloudflare/tunnels/<service-host>-main.credentials.json.age`

## Proposed execution sequence

### Phase 0: Inventory live Cloudflare tunnel state

Refresh exporter output, then record a small manual manifest for the current
tunnel adoption wave.

For each live tunnel, capture:

- intended Terraform key
- Cloudflare tunnel UUID
- tunnel display name
- whether config is `local` or `cloudflare`
- current ingress/default config source
- any private routes and their route IDs
- runtime credentials JSON file destination
- host(s) that should run the connector

Suggested session artifacts under `docs/ai/runs/<session>/`:

- `cloudflare-platform.tfstate.before-tunnels.json`
- `cloudflare-tunnels-manifest.json`
- `cloudflare-tunnels-notes.md`

Important: if there is currently **one** live tunnel but the desired steady
state is **multiple per-host tunnels**, do not import it under a temporary key
and split it later by accident. Decide the desired tunnel topology first.

### Phase 1: Author repo inputs before any import

1. Add `tf/cloudflare-platform/tunnels.auto.tfvars` with final stable keys.
2. If needed, add encrypted tunnel tfvars under
   `data/secrets/tf/cloudflare/tunnels/`.
3. If host-managed config is the choice, explicitly set imported tunnels to
   `config_src = "local"`.
4. If Cloudflare-managed config is the choice, mirror the live ingress config
   into `tunnel_configs` before importing that resource.
5. Do **not** wait on `scripts/cloudflare-export.py` changes before doing the
  first tunnel adoption pass.

## Phase 2: Initialize and snapshot state

1. Run OpenTofu init for `tf/cloudflare-platform/`.
2. Pull and save the current remote state snapshot under
   `docs/ai/runs/<session>/` before the first import.
3. Record the live import manifest in the same session folder.

## Phase 3: Import serially

Use serial imports only; do not run concurrent imports against the same remote
backend.

Import order:

1. tunnel object
   - address:
     `module.cloudflare_platform.cloudflare_zero_trust_tunnel_cloudflared.tunnel["<key>"]`
   - import ID: `<account_id>/<tunnel_id>`
2. tunnel config, if applicable
   - address:
     `module.cloudflare_platform.cloudflare_zero_trust_tunnel_cloudflared_config.config["<key>"]`
   - import ID: `<account_id>/<tunnel_id>`
3. private routes, if any
   - address shape:
     `module.cloudflare_platform.cloudflare_zero_trust_tunnel_cloudflared_route.route["<key>/<cidr>"]`
   - import ID: `<account_id>/<route_id>`

Recommended first-pass boundary:

1. import tunnel objects first
2. stop and run `plan`
3. only import configs if we explicitly want Cloudflare-managed ingress to be
  the source of truth
4. only import routes if live private routes actually exist and are intended to
  remain repo-managed

## Phase 4: Verify before wider use

After each import wave:

1. `tofu -chdir=tf/cloudflare-platform state list`
2. `tofu -chdir=tf/cloudflare-platform plan -refresh-only`
3. `tofu -chdir=tf/cloudflare-platform plan`
4. `./scripts/nixbot-deploy.sh --action tf-platform --dry`

Do not apply until the tunnel slice is either no-op or only shows deliberately
accepted drift.

## Phase 5: Converge host runtime config

After state adoption is stable:

1. Replace placeholder tunnel UUIDs in host Nix config with real imported UUIDs.
2. Stage the real encrypted credential JSONs in `data/secrets/cloudflare/tunnels/`.
3. If Cloudflare-managed config was chosen, simplify the host-side tunnel config
   so the host only supplies credentials/runtime behavior.
4. If host-managed config was chosen, keep ingress/default rules in host Nix and
   avoid importing Cloudflare-side config unless that live config must be
   preserved temporarily.

## March 17 execution outcome

Completed on 2026-03-17:

- One modeled tunnel object and its Cloudflare-managed config were imported into
  `tf/cloudflare-platform` state under the final repo key for the bastion-host
  tunnel.
- The tunnel exporter generated
  `data/secrets/tf/cloudflare/tunnels/account.tfvars.age` for the adopted
  tunnel surface.
- No private tunnel routes were present in the live account during this import
  wave.
- The targeted tunnel plan returned to no-op after exporter normalization kept
  provider-style empty `origin_request` blocks where needed.
- The temporary run manifest and pre-import state snapshot for this wave were
  folded back into this note and cleaned out of `docs/ai/runs/`.

## Remaining questions

- Should future tunnels keep ingress host-managed in NixOS, or should they move
  to Cloudflare-managed tunnel config in Terraform by default?
- Are there any additional live private network routes that still need
  adoption?
- Do any future tunnel waves need a preserved tunnel secret in Terraform state,
  or is the agenix-managed credentials JSON sufficient for runtime?

## Recommended next move

Use the current imported tunnel as the reference pattern for any follow-up wave:

1. refresh tunnel exporter output
2. stage host credential JSONs in agenix
3. record a short run-local manifest under `docs/ai/runs/<session>/`
4. import tunnel objects serially, then configs/routes only where they are
   truly intended to be repo-managed
5. fold the durable outcome back into this note and delete the temporary run
   artifacts

## Practical state-transition plan

### If the goal is to adopt another tunnel now

1. create `tf/cloudflare-platform/tunnels.auto.tfvars` with final logical keys
  and tunnel names
2. choose `config_src = "local"` for any tunnel whose ingress still lives in
  host NixOS
3. record the live tunnel UUIDs and any route IDs in a session manifest
4. snapshot `tf/cloudflare-platform` remote state
5. import tunnel objects serially
6. run:
  - `tofu -chdir=tf/cloudflare-platform state list`
  - `tofu -chdir=tf/cloudflare-platform plan -refresh-only`
  - `tofu -chdir=tf/cloudflare-platform plan`
7. only proceed to config/route imports if the object-only plan is stable and
  ownership boundaries are still clear

### If the goal is to improve repeatability after adoption

Do as a separate follow-up task:

1. extend `scripts/cloudflare-export.py` with a tunnel surface
2. add tunnel-specific output paths under `data/secrets/tf/cloudflare/tunnels/`
3. update `docs/ai/playbooks/cloudflare-state-adoption.md` so tunnels are no
  longer treated as out of scope
4. replace placeholder host tunnel UUIDs with the imported real UUIDs once the
  platform state is settled
