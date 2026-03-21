# Terraform

`tf/` contains provider-specific OpenTofu projects plus reusable modules.

Terraform secret tfvars are discovered by convention:

- provider-wide secrets: `data/secrets/tf/<provider>/`
- project/root-specific secrets: `data/secrets/tf/<project>/`

Project secrets load after provider secrets, so project-specific values win.

## Projects

### Active

- `cloudflare-dns/`: pre-deploy Cloudflare DNS phase
- `cloudflare-platform/`: Cloudflare platform phase for non-app resources
- `cloudflare-apps/`: post-build Cloudflare apps phase

### Inactive

- `gcp-bootstrap/`: manual Google Cloud bootstrap phase for the control folder,
  project, service account, and state bucket; state stored in the shared R2
  backend
- `gcp-platform/`: Google Cloud platform phase for managed projects and their
  current in-project resources

Runnable projects follow the naming convention `tf/<provider>-<phase>/`.
`scripts/nixbot-deploy.sh` keeps explicit per-phase project lists in the script,
so:

- `--action tf-dns` runs the projects listed under the `dns` phase
- `--action tf-platform` runs the projects listed under the `platform` phase
- `--action tf-apps` runs the projects listed under the `apps` phase
- `--action tf/<project>` runs just that configured project

Normal editing flow:

- comment or uncomment a project name in the single `TF_PROJECT_NAMES` array in
  `scripts/nixbot-deploy.sh`
- keep the directory name in `tf/<provider>-<phase>/` form so provider/phase
  conventions still work

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
