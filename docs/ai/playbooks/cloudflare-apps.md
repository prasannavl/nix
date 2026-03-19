# Cloudflare Apps In Repo

## Goal

Create, update, build, stage, and deploy repo-managed Cloudflare apps through a
single package + OpenTofu workflow.

## Source Of Truth

- Aggregate app package: `pkgs/cloudflare-apps/flake.nix`
- Per-app source: `pkgs/cloudflare-apps/<app>/`
- Optional per-app build/stage helper: `pkgs/cloudflare-apps/<app>/flake.nix`
- Terraform inputs:
  `data/secrets/tf/cloudflare/workers/<group>.tfvars.age` or
  `tf/cloudflare-apps/workers.auto.tfvars`
- Terraform resources: `tf/modules/cloudflare/workers.tf`

## Mental Model

1. `tf/cloudflare-apps` is the infrastructure phase.
2. `pkgs/cloudflare-apps/flake.nix` is the aggregate package for that phase.
3. If an app needs generated local assets, its child flake exposes `build` and
   `stage`.
4. `scripts/nixbot-deploy.sh --action tf-apps` runs the aggregate `stage` step
   before OpenTofu.
5. The aggregate `stage` step calls each child app's `#stage` helper.
6. Child apps may expose app-local helpers such as `wrangler-deploy`, but the
   Terraform deploy path stays aggregate at the project level.

## Create A New App

1. Create the source tree under `pkgs/cloudflare-apps/<app>/`.
2. If the app is source-only, stop there and reference those files directly from
   Terraform.
3. If the app needs generated local output such as a `result` symlink, add
   `pkgs/cloudflare-apps/<app>/flake.nix` with at least `packages.build` and
   `packages.stage`.
4. Add public-safe definitions in `tf/cloudflare-apps/workers.auto.tfvars` or
   sensitive ones in `data/secrets/tf/cloudflare/workers/`.
5. Set `compatibility_date` explicitly.
6. Add bindings, routes, `script_subdomain`, cron triggers, or custom domains as
   needed.

## Deploy

Aggregate Terraform flow:

1. Run `nix run .#pkgs.x86_64-linux.cloudflare-apps.stage` if you want to stage
   assets explicitly.
2. Run `./scripts/nixbot-deploy.sh --action tf-apps --dry`.
3. Review the Worker service, version, deployment, route, and custom-domain
   changes.
4. Run `./scripts/nixbot-deploy.sh --action tf-apps`.

Per-app direct Wrangler flow:

- `nix run .#pkgs.x86_64-linux.cloudflare-apps.<name>.wrangler-deploy`

There is also a single aggregate entrypoint:

- `nix build .#pkgs.x86_64-linux.cloudflare-apps`
- `nix run .#pkgs.x86_64-linux.cloudflare-apps.stage`
- `nix run .#pkgs.x86_64-linux.cloudflare-apps.deploy -- --dry`

## Adopt An Existing Dashboard Worker

1. Run `python scripts/archive/cloudflare-export.py` to refresh repo-side app
   source and tfvars from the live account.
2. Normalize the app under `pkgs/cloudflare-apps/<app>/`.
3. Add a child flake only if that app needs a generated local tree before
   Terraform reads it.
4. Import the Worker, version/deployment-adjacent resources, routes, and custom
   domains before the first apply.

## Notes

- Worker `secret_text` bindings must be supplied from encrypted tfvars; they
  cannot be read back from Cloudflare.
- Assets-only Workers are valid even when they have no modules or
  `main_module`.
- Keep the per-project build/stage logic in `pkgs/<project>/flake.nix`, not in
  one-off branches inside the deploy script.
