# NixOS Config

This repo contains my NixOS and Home Manager configuration, organized as small
modules and composed via `flake.nix`.

## Layout

- `flake.nix`: flake inputs and system definition.
- `hosts/<host>/default.nix`: host-specific system definition and module
  imports.
- `users/pvl/default.nix`: Base user + Home Manager module builder for `pvl`.
- `lib/*.nix`: single-topic NixOS modules imported directly by hosts.
- `overlays/`: custom overlays used by the system.
- `hosts/nixbot.nix`: deploy mapping (plain Nix attrset).
- `data/secrets/default.nix`: agenix recipients map for `*.age` files.

## GitHub Actions Deploy

Workflow: `.github/workflows/nixbot.yaml`.

- Push to `master`: trigger build-only run.
- Manual (`workflow_dispatch`): set `hosts` and optionally deploy.

The workflow is intentionally thin: it only SSHes into the configured bastion
host via `scripts/nixbot-deploy.sh --bastion-trigger`.

Security note: deploy does **not** SCP/upload a script to bastion at runtime.
The bastion forced-command key is restricted to the pre-installed
`/var/lib/nixbot/nixbot-deploy.sh` path, so CI/local trigger only invokes that
allowed command.

## Deployment

High-level architecture:

- GitHub Actions connects to bastion (`pvl-x2`) using a restricted ingress key
  and forced command (`ssh-gate`).
- Bastion runs `scripts/nixbot-deploy.sh` to build/deploy selected NixOS hosts.
- Deploy SSH key material is stored as age-encrypted secrets in
  `data/secrets/*.age`, with bootstrap and rotation rules documented in
  deployment docs.

Deployment-specific architecture, key model, bootstrap flow, rotation procedure,
and operational notes are documented in:

- `docs/deployment.md`

Primary files for deployment are:

- `hosts/nixbot.nix` (deploy target mapping/defaults)
- `scripts/nixbot-deploy.sh` (build/deploy orchestration)
- `lib/nixbot/bastion.nix` (bastion-side nixbot setup)
- `scripts/nixbot-deploy.sh` re-execs itself into a `nix shell` toolchain so
  deploy runs use the same packaged command set everywhere, pinned via this
  repo's flake inputs.

## OpenTofu

Infrastructure managed outside NixOS modules lives in `tf/`.

- `tf/`: OpenTofu configuration, currently used for Cloudflare DNS.
- `tf/README.md`: documents the Cloudflare R2-backed OpenTofu state setup.
- `scripts/nixbot-deploy.sh --action tf`: runs the OpenTofu stack locally or
  through the bastion-trigger path used by `nixbot`.
- `.github/workflows/nixbot.yaml`: can dispatch `action=tf` through the same
  bastion-based workflow path used for build/deploy.
- Terraform credentials can be stored as repo-managed age secrets under
  `data/secrets/cloudflare/*.key.age`; `--action tf` decrypts them on demand
  using the existing bastion age key.

Deploy ordering notes:

- `hosts/nixbot.nix` may declare per-host `deps = [ ... ];` for build/deploy
  ordering.
- `scripts/nixbot-deploy.sh` still builds all selected hosts before starting
  deploy.
- Build parallelism is controlled by `DEPLOY_BUILD_JOBS` / `--build-jobs`.
- Deploy parallelism is controlled by `DEPLOY_JOBS` / `--deploy-jobs`.
- `DEPLOY_BASTION_FIRST` / `--bastion-first` prioritizes the bastion host first
  for both build ordering and deploy waves when that host is selected. This
  override ignores the bastion host's own `deps` for ordering.
- Deploy derives dependency waves from `deps`, so dependents wait for their
  selected dependencies while same-wave hosts can still run in parallel.
