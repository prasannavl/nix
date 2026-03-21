# Cloudflare Apps In Repo

## Goal

Create, update, build, and deploy repo-managed Cloudflare apps through a single
package + OpenTofu workflow.

## Source Of Truth

- Aggregate app package: `pkgs/cloudflare-apps/flake.nix`
- Per-app source: `pkgs/cloudflare-apps/<app>/`
- Optional per-app build helper: `pkgs/cloudflare-apps/<app>/flake.nix`
- Terraform inputs: `data/secrets/tf/cloudflare/*.tfvars.age`,
  `data/secrets/tf/cloudflare-apps/project-<group>.tfvars.age`, or
  `tf/cloudflare-apps/workers.auto.tfvars`
- Terraform resources: `tf/modules/cloudflare/workers.tf`

## Mental Model

1. `tf/cloudflare-apps` is the infrastructure phase.
2. `pkgs/cloudflare-apps/flake.nix` is the aggregate package for that phase.
3. If an app needs generated local assets, its child flake exposes `build`.
4. `nixbot tf-apps` warms app build outputs through
   `nix build path:pkgs/<project>#build --no-link`; the old repo-local `stage`
   flow is gone.
5. Terraform resolves app directories to their real `#build` outputs during
   plan/apply rather than depending on repo-local `result` symlinks.
6. Legacy `.../result` paths are normalized to the same `#build` output when
   their parent app directory contains `flake.nix`.
7. Child apps may expose app-local helpers such as `wrangler-deploy`, but the
   Terraform deploy path stays aggregate at the project level.

## Create A New App

1. Create the source tree under `pkgs/cloudflare-apps/<app>/`.
2. If the app is source-only, stop there and reference those files directly from
   Terraform.
3. If the app needs generated local output, add
   `pkgs/cloudflare-apps/<app>/flake.nix` with at least `packages.build`.
4. Add public-safe definitions in `tf/cloudflare-apps/workers.auto.tfvars` or
   sensitive ones in `data/secrets/tf/cloudflare-apps/`.
5. Set `compatibility_date` explicitly.
6. Add bindings, routes, `script_subdomain`, cron triggers, or custom domains as
   needed.

## Deploy

Aggregate Terraform flow:

1. Run `nix build .#pkgs.x86_64-linux.cloudflare-apps --no-link` if you want to
   warm the app builds explicitly.
2. Run `nixbot tf-apps --dry`.
3. Review the Worker service, version, deployment, route, and custom-domain
   changes.
4. Run `nixbot tf-apps`.

Per-app direct Wrangler flow:

- `nix run .#pkgs.x86_64-linux.cloudflare-apps.<name>.wrangler-deploy`

There is also a single aggregate entrypoint:

- `nix build .#pkgs.x86_64-linux.cloudflare-apps`
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
- Assets-only Workers are valid even when they have no modules or `main_module`.
- Keep the per-project build logic in `pkgs/<project>/flake.nix`, not in one-off
  branches inside the deploy script.
- Direct Wrangler deploys should also target the resolved `#build` output via
  `--assets <store-path>`, not a repo-local staged tree.
