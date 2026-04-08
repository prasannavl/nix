# Terraform

`tf/` contains the repo's OpenTofu projects and shared Terraform modules.

## Active Projects

- `cloudflare-dns/`
- `cloudflare-platform/`
- `cloudflare-apps/`

## Inactive Projects

- `gcp-bootstrap/`
- `gcp-platform/`

## Main Commands

- `nixbot tf`
- `nixbot tf-dns`
- `nixbot tf-platform`
- `nixbot tf-apps`
- `nixbot tf/<project>`

## Secret Loading

Terraform secret tfvars are discovered by convention:

- provider-wide secrets: `data/secrets/tf/<provider>/`
- project-specific secrets: `data/secrets/tf/<project>/`

Project-specific values override provider-wide values.

## Package Build Convention

Apps phases may also have a matching package namespace at `pkgs/<project>/`.

When `pkgs/<project>/flake.nix` exists, `nixbot` prepares that project with:

```sh
nix build ./pkgs/<project>#build --no-link
```

This keeps app build logic next to the app sources instead of encoding it in the
deploy script.

## Phase Order

`nixbot tf`:

1. `tf/cloudflare-dns/`
2. `tf/cloudflare-platform/`
3. `tf/gcp-platform/`
4. `tf/cloudflare-apps/`

`nixbot run`:

1. `tf/cloudflare-dns/`
2. `tf/cloudflare-platform/`
3. `tf/gcp-platform/`
4. host build and deploy
5. `tf/cloudflare-apps/`

## Shared Modules

- `modules/cloudflare/`
- `modules/gcp/bootstrap/`
- `modules/gcp/project-dev/`

## Detailed Reference

The sections below cover project conventions and lower-frequency operational
detail.

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
`nixbot` keeps explicit per-phase project lists in the packaged action, so:

- `nixbot tf-dns` runs the projects listed under the `dns` phase
- `nixbot tf-platform` runs the projects listed under the `platform` phase
- `nixbot tf-apps` runs the projects listed under the `apps` phase
- `nixbot tf/<project>` runs just that configured project

Normal editing flow:

- comment or uncomment a project name in the single `TF_PROJECT_NAMES` array in
  the packaged nixbot source
- keep the directory name in `tf/<provider>-<phase>/` form so provider/phase
  conventions still work

## Modules

- `modules/cloudflare/`: shared Cloudflare implementation module used by all
  three Cloudflare projects
- `modules/gcp/bootstrap/`: shared GCP bootstrap implementation
  - `modules/gcp/project-dev/`: explicit dev project layout split by concern
