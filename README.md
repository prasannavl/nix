# NixOS Config

This repo contains my NixOS and Home Manager configuration, organized as small
modules and composed via `flake.nix`.

## Layout

- `flake.nix`: flake inputs and system definition.
- `pkgs/`: repo-local runnable source trees; each package owns its own flake and
  is aggregated into a custom top-level flake attr such as
  `.#pkgs.<system>.hello-rust`, `.#pkgs.<system>.cloudflare-apps`,
  `.#pkgs.<system>.cloudflare-apps.deploy`, or
  `.#pkgs.<system>.cloudflare-apps.llmug-hello.wrangler-deploy`.
- `pkgs/ext/`: standalone derivation definitions consumed by overlays and helper
  scripts.
- `hosts/<host>/default.nix`: host-specific system definition and module
  imports.
- `users/pvl/default.nix`: Base user + Home Manager module builder for `pvl`.
- `lib/*.nix`: single-topic NixOS modules imported directly by hosts.
- `lib/internal/`: internal flake/tooling helpers such as linting and the custom
  flake tree helper.
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

- GitHub Actions connects to the configured bastion host using a restricted
  ingress key and forced command (`ssh-gate`).
- Bastion runs `scripts/nixbot-deploy.sh` to build/deploy selected NixOS hosts.
- Deploy SSH key material is stored as age-encrypted secrets in
  `data/secrets/*.age`, with bootstrap and rotation rules documented in
  deployment docs.

Deployment-specific architecture, key model, bootstrap flow, rotation procedure,
and operational notes are documented in:

- `docs/deployment.md`
- `docs/nixbot-security-trust-model.md`

Primary files for deployment are:

- `hosts/nixbot.nix` (deploy target mapping/defaults)
- `scripts/nixbot-deploy.sh` (build/deploy orchestration)
- `lib/nixbot/bastion.nix` (bastion-side nixbot setup)
- `lib/nixbot/default.nix` (nixbot user module with sudo/identity)
- `scripts/nixbot-deploy.sh` runs in a cached `nix shell` toolchain with pinned
  commands (`nix`, `age`, `git`, `jq`, `nixos-rebuild`, `openssh`, `opentofu`)
  so deploy runs use consistent command sets everywhere.

## Deploy Actions

`scripts/nixbot-deploy.sh` supports multiple actions:

- `--action all` (default): full build/deploy flow with optional TF phases
- `--action deploy`: host build and deploy only
- `--action build`: host build only
- `--action tf`: all Terraform phases (tf-dns, tf-platform, tf-apps)
- `--action tf-dns`: Cloudflare DNS only
- `--action tf-platform`: Cloudflare platform resources only
- `--action tf-apps`: Cloudflare Workers/package deployments only

## OpenTofu

Infrastructure managed outside NixOS modules lives in `tf/`.

- `tf/`: Terraform/OpenTofu project container.
- `tf/cloudflare-dns/`: pre-deploy Cloudflare DNS OpenTofu project.
- `tf/cloudflare-platform/`: Cloudflare platform OpenTofu project for non-app
  resources.
- `tf/cloudflare-apps/`: post-build Cloudflare Workers/package OpenTofu project.
- `tf/modules/cloudflare/`: Cloudflare module implementation shared by the
  phase-specific projects.
- `tf/README.md`: Terraform project layout docs.
- `scripts/nixbot-deploy.sh --action tf-dns|tf-platform|tf-apps`: runs the
  phase-specific OpenTofu projects locally or through the bastion-trigger path
  used by `nixbot`. Project discovery is suffix-based, so future
  `tf/<provider>-dns`, `tf/<provider>-platform`, and `tf/<provider>-apps`
  projects participate automatically.
- `.github/workflows/nixbot.yaml`: can dispatch the same bastion-based
  build/deploy flow and the standard Terraform phase actions only; it does not
  expose per-project `tf/<project>` actions.
- Terraform credentials can be stored as repo-managed age secrets under
  `data/secrets/cloudflare/*.key.age`; the phase-specific OpenTofu actions
  decrypt them on demand using the existing bastion age key.

## Deploy Ordering

- `scripts/nixbot-deploy.sh --action all` runs Cloudflare in phases: `tf-dns`,
  `tf-platform`, host build/deploy, then `tf-apps`.
- `scripts/nixbot-deploy.sh --action tf` runs the Terraform phases only:
  `tf-dns`, `tf-platform`, then `tf-apps`.
- `hosts/nixbot.nix` may declare per-host `deps = [ ... ];` for build/deploy
  ordering.
- All selected hosts are built before deploy starts.
- Build parallelism: `DEPLOY_BUILD_JOBS` / `--build-jobs`.
- Deploy parallelism: `DEPLOY_JOBS` / `--deploy-jobs`.
- `DEPLOY_BASTION_FIRST` / `--bastion-first` prioritizes the bastion host first
  for both build ordering and deploy waves when selected.
- Deploy derives dependency waves from `deps`.

## Linting

- `nix fmt` applies the repo formatter configured in `treefmt.toml`.
- `nix run path:.#lint` runs the shared lint suite across the whole repo.
- `nix run path:.#lint-diff` runs the diff-scoped lint suite used for local
  incremental checks.
- Repo-wide gates today: `treefmt --ci`, `actionlint`, and `tflint` for `tf/*-*`
  projects, plus full-repo `statix`, `deadnix`, `shellcheck`, and
  `markdownlint-cli2` under `.#lint`.
- Diff-scoped gates in `.#lint-diff`: `statix`, `deadnix`, `shellcheck`, and
  `markdownlint-cli2` run only on changed files so the hook protects new edits
  with faster local feedback.
- Flake package `.#lint-deps` warms the full runnable `.#lint` closure so CI can
  realize the shared lint wrappers and tool dependencies ahead of the actual
  lint step.
- `./scripts/git-install-hooks.sh` configures Git to use `.githooks/`; the repo
  pre-commit hook runs `nix run path:.#lint-diff` before allowing a commit.
