# Cloudflare Workers In Repo

## Goal

Create, update, and deploy Cloudflare Workers entirely from the repo using the
existing Nix and OpenTofu flow.

## Source Of Truth

- Worker source: `pkgs/cloudflare-workers/<worker>/`
- Worker Terraform inputs:
  `data/secrets/tf/cloudflare/workers/<group>.tfvars.age` or
  `tf/cloudflare-apps/workers.auto.tfvars`
- Worker Terraform resources: `tf/modules/cloudflare/workers.tf`

## Create A New Worker

1. Create the source tree under `pkgs/cloudflare-workers/<worker>/`.
2. For a module Worker, add the entrypoint file, then reference it from
   `main_module` and `modules`.
3. For an assets-only Worker, create `pkgs/cloudflare-workers/<worker>/assets/`
   and use
   `assets = { directory =
   "../../pkgs/cloudflare-workers/<worker>/assets" }`.
4. Put public-safe definitions in `tf/cloudflare-apps/workers.auto.tfvars` or
   sensitive ones in the right encrypted file under
   `data/secrets/tf/cloudflare/workers/`.
5. Set `compatibility_date` explicitly.
6. Add any bindings, routes, `script_subdomain`, cron triggers, or
   `custom_domains`.

## Assign A Domain

1. Add route bindings under `routes = [{ zone_name, pattern }]` when you want a
   route like `example.com/api/*`.
2. Add `custom_domains = [{ zone_name, hostname }]` when the Worker should own a
   hostname like `worker.example.com`.
3. If the hostname needs an independent advanced certificate outside the Worker
   custom-domain lifecycle, declare it under `zone_certificate_packs` in the
   matching `zone-security/<group>.tfvars.age` file.

## Deploy

1. Run `./scripts/nixbot-deploy.sh --action tf-apps --dry`.
2. Review the Worker service, version, deployment, route, and custom-domain
   changes.
3. Run `./scripts/nixbot-deploy.sh --action tf-apps`.

For an existing repo-local Worker, there is also a Nix-backed path:

1. In `pkgs/cloudflare-workers/<worker>/`, run `nix build` once the worker
   directory is tracked by Git. Before that, use `nix build path:.`.
2. In `pkgs/cloudflare-workers/<worker>/`, run
   `nix run path:.#deploy -- --dry` to sync and immediately hand off to the
   normal Cloudflare OpenTofu deploy flow.
3. The root flake exposes the build as
   `.#pkgs.x86_64-linux.cloudflare-workers.<worker>` and the deploy installable
   as `.#pkgs.x86_64-linux.cloudflare-workers.<worker>.deploy`.

## Adopt An Existing Dashboard Worker

1. Run `python scripts/cloudflare-export.py` to refresh the repo-side Worker
   source and tfvars from the live account.
2. Review the generated Worker file under `data/secrets/tf/cloudflare/workers/`.
3. Normalize the Worker into the repo-local source layout under
   `pkgs/cloudflare-workers/<worker>/` so Terraform can deploy it directly from
   this repository.
4. Review any related zone SSL resources under
   `data/secrets/tf/cloudflare/zone-security/`.
5. Import the Worker, version/deployment-adjacent resources, routes, and custom
   domains in a separate pass before the first apply.

## Notes

- Worker `secret_text` bindings must be supplied from encrypted tfvars; they
  cannot be read back from Cloudflare.
- Assets-only Workers are valid in this repo even when they have no modules or
  `main_module`.
