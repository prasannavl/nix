# Terraform

`tf/` contains provider-specific OpenTofu projects plus reusable modules.

## Projects

- `cloudflare-dns/`: pre-deploy Cloudflare DNS phase
- `cloudflare-platform/`: Cloudflare platform phase for non-app resources
- `cloudflare-apps/`: post-build Cloudflare apps phase

Runnable projects follow the naming convention `tf/<provider>-<phase>/`.
`scripts/nixbot-deploy.sh` discovers projects by suffix, so:

- `--action tf-dns` runs every `tf/*-dns` project
- `--action tf-platform` runs every `tf/*-platform` project
- `--action tf-apps` runs every `tf/*-apps` project

## Package Convention

Apps phases may also have a matching package namespace at `pkgs/<project>/`.
When `pkgs/<project>/flake.nix` exists, `scripts/nixbot-deploy.sh` prepares that
project by running `nix run path:pkgs/<project>#stage` before OpenTofu. This
keeps build/stage logic grouped with the app sources instead of hardcoding
one-off behavior in the deploy script.

## Modules

- `modules/cloudflare/`: shared Cloudflare implementation module used by all
  three Cloudflare projects

Use:

- `./scripts/nixbot-deploy.sh --action tf`
- `./scripts/nixbot-deploy.sh --action tf-dns`
- `./scripts/nixbot-deploy.sh --action tf-platform`
- `./scripts/nixbot-deploy.sh --action tf-apps`
- `./scripts/nixbot-deploy.sh --action all`

Phase order for `--action tf`:

1. `tf/cloudflare-dns/`
2. `tf/cloudflare-platform/`
3. `tf/cloudflare-apps/`

Phase order for `--action all`:

1. `tf/cloudflare-dns/`
2. `tf/cloudflare-platform/`
3. host build/deploy
4. `tf/cloudflare-apps/`
