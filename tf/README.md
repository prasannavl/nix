# OpenTofu

`tf/` contains the repo's OpenTofu projects and shared modules.

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

Secret tfvars are discovered by convention:

- provider-wide secrets: `data/secrets/globals/tf/<provider>/`
- project-specific secrets: `data/secrets/globals/tf/<project>/`

Project-specific values override provider-wide values.

## Package Build Convention

Apps phases may also have a matching package namespace under `pkgs/`.

For app preparation, `nixbot` builds the canonical package definition directly:

```sh
nix build --file <package-dir>/default.nix --no-link
```

This keeps app build logic next to the app sources instead of encoding it in the
deploy script.

## Phase Order

`nixbot tf`:

1. `tf/cloudflare-dns/`
2. `tf/cloudflare-platform/`
3. `tf/cloudflare-apps/`

`nixbot run`:

1. `tf/cloudflare-dns/`
2. `tf/cloudflare-platform/`
3. host build and deploy
4. `tf/cloudflare-apps/`

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

Today that means:

- `tf-platform` covers only `cloudflare-platform`
- `gcp-platform` is manual: enable it in `nixbot`'s `TF_PROJECT_NAMES` first,
  then `nixbot tf/gcp-platform` runs it

## Modules

- `modules/cloudflare/`: shared Cloudflare implementation module used by all
  three Cloudflare projects
- `modules/gcp/bootstrap/`: shared GCP bootstrap implementation
  - `modules/gcp/project-dev/`: explicit dev project layout split by concern
