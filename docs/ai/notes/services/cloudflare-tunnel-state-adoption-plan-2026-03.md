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
- There are currently no tunnel tfvars in:
  - `tf/cloudflare-platform/*.auto.tfvars`
  - `data/secrets/tf/cloudflare/**`
- `scripts/cloudflare-export.py` does not currently export tunnel data.
- Host runtime secret paths are already reserved in `data/secrets/default.nix`
  for:
  - `data/secrets/cloudflare/tunnels/pvl-x2-main.credentials.json.age`
  - `data/secrets/cloudflare/tunnels/llmug-rivendell-main.credentials.json.age`
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

## Recommended target layout

### Public-safe Terraform inputs

Create a new tracked file:

- `tf/cloudflare-platform/tunnels.auto.tfvars`

Suggested contents:

- `tunnels`
  - stable Terraform keys such as `pvl-x2-main` or `llmug-rivendell-main`
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

- `data/secrets/cloudflare/tunnels/pvl-x2-main.credentials.json.age`
- `data/secrets/cloudflare/tunnels/llmug-rivendell-main.credentials.json.age`

## Proposed execution sequence

### Phase 0: Inventory live Cloudflare tunnel state

Collect a manual manifest for the current tunnel adoption wave because there is
no exporter support yet.

For each live tunnel, capture:

- intended Terraform key
- Cloudflare tunnel UUID
- tunnel display name
- whether config is `local` or `cloudflare`
- current ingress/default config source
- any private routes and their route IDs
- runtime credentials JSON file destination
- host(s) that should run the connector

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

## Open questions

- Is the live tunnel topology one shared tunnel or one tunnel per host?
- Should ingress remain host-managed in NixOS, or move to Cloudflare-managed
  tunnel config in Terraform?
- Are there any live private network routes that also need adoption?
- Do we need to preserve an existing tunnel secret in Terraform state, or is the
  agenix-managed credentials JSON sufficient for runtime?

## Recommended next move

Answer the ownership-boundary question first:

- **If we want the least disruptive adoption:** import only the tunnel object(s)
  first and keep config host-managed.
- **If we want full Cloudflare control-plane ownership:** import tunnel objects,
  configs, and routes together, then reduce host configs accordingly.

Once that choice is made, the actual import pass is straightforward and can be
executed with a short session manifest under `docs/ai/runs/<session>/`.
