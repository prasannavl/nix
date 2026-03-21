# Terraform

`tf/` contains provider-specific OpenTofu projects plus reusable modules.

## Projects

### Active

- `cloudflare-dns/`: pre-deploy Cloudflare DNS phase
- `cloudflare-platform/`: Cloudflare platform phase for non-app resources
- `cloudflare-apps/`: post-build Cloudflare apps phase

### Inactive

- `gcp-bootstrap/`: manual Google Cloud bootstrap phase for the control folder,
  project, service account, and state bucket
- `gcp-platform/`: Google Cloud platform phase for managed projects and their
  current in-project resources

Runnable projects follow the naming convention `tf/<provider>-<phase>/`.
`scripts/nixbot-deploy.sh` discovers projects by suffix, so:

- `--action tf-dns` runs every `tf/*-dns` project
- `--action tf-platform` runs every `tf/*-platform` project
- `--action tf-apps` runs every `tf/*-apps` project

## Package Convention

Apps phases may also have a matching package namespace at `pkgs/<project>/`.
When `pkgs/<project>/flake.nix` exists, `scripts/nixbot-deploy.sh` prepares that
project by running `nix build path:pkgs/<project>#build --no-link` before
OpenTofu. This keeps build/stage logic grouped with the app sources instead of
hardcoding one-off behavior in the deploy script.

## Modules

- `modules/cloudflare/`: shared Cloudflare implementation module used by all
  three Cloudflare projects
- `modules/gcp/bootstrap/`: shared GCP bootstrap implementation
- `modules/gcp/project-dev/`: explicit dev project layout split by concern

Use:

- `cd tf/gcp-bootstrap && tofu init && tofu apply`
- `./scripts/nixbot-deploy.sh --action tf`
- `./scripts/nixbot-deploy.sh --action tf-dns`
- `./scripts/nixbot-deploy.sh --action tf-platform`
- `./scripts/nixbot-deploy.sh --action tf-apps`
- `./scripts/nixbot-deploy.sh --action all`

Phase order for `--action tf`:

1. `tf/cloudflare-dns/`
2. `tf/cloudflare-platform/`
3. `tf/gcp-platform/`
4. `tf/cloudflare-apps/`

Phase order for `--action all`:

1. `tf/cloudflare-dns/`
2. `tf/cloudflare-platform/`
3. `tf/gcp-platform/`
4. host build/deploy
5. `tf/cloudflare-apps/`
