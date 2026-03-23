# Nix

This is the nix driven monorepo, organized as small modules and composed via
`flake.nix`.

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
- `lib/flake/`: flake support helpers such as linting and the custom flake tree
  helper.
- `overlays/`: custom overlays used by the system.
- `hosts/nixbot.nix`: deploy mapping (plain Nix attrset).
- `data/secrets/default.nix`: agenix recipients map for `*.age` files.

## GitHub Actions Deploy

Workflow: `.github/workflows/nixbot.yaml`.

- Push to `master`: trigger build-only run.
- Manual (`workflow_dispatch`): set `hosts` and optionally deploy.

The workflow is intentionally thin: it only SSHes into the configured bastion
host via the packaged `nixbot` entrypoint with `--bastion-trigger`.

Security note: deploy does **not** SCP/upload a script to bastion at runtime.
The bastion forced-command key is restricted directly to the packaged `nixbot`
command from `pkgs/nixbot`, so CI/local trigger only invokes that allowed
command.

## Deployment

High-level architecture:

- GitHub Actions connects to the configured bastion host using a restricted
  ingress key and forced command (`ssh-gate`).
- Bastion runs the packaged `nixbot` command directly from the Nix store to
  build/deploy selected NixOS hosts.
- Deploy SSH key material is stored as age-encrypted secrets in
  `data/secrets/*.age`, with bootstrap and rotation rules documented in
  deployment docs.

Deployment-specific architecture, key model, bootstrap flow, rotation procedure,
and operational notes are documented in:

- `docs/deployment.md`
- `docs/nixbot-security-trust-model.md`

Primary files for deployment are:

- `hosts/nixbot.nix` (deploy target mapping/defaults)
- `pkgs/nixbot/` (canonical packaged nixbot source)
- `nixbot` (packaged deployment entrypoint)
- `pkgs/nixbot/flake.nix` (packaged nixbot application wrapper)
- `lib/nixbot/bastion.nix` (bastion-side nixbot setup)
- `lib/nixbot/default.nix` (nixbot user module with sudo/identity)
- `nixbot` runs in a cached `nix shell` toolchain with pinned commands (`nix`,
  `age`, `git`, `jq`, `nixos-rebuild`, `openssh`, `opentofu`) so deploy runs use
  consistent command sets everywhere.
- The packaged `nixbot` wrapper ships that same runtime toolchain directly and
  executes the packaged nixbot entrypoint without depending on repo-relative
  flake discovery.

## Deploy Actions

`nixbot` supports multiple top-level actions:

- `deps`: enter the pinned nixbot runtime shell, verify the required toolchain,
  and exit
- `check-deps`: verify the required toolchain is already available in the
  current environment and exit
- `run` (default full workflow): build/deploy flow with optional TF phases
- `deploy`: host build and deploy only
- `build`: host build only
- `tf`: all Terraform phases (tf-dns, tf-platform, tf-apps)
- `tf-dns`: Cloudflare DNS only
- `tf-platform`: Cloudflare platform resources only
- `tf-apps`: Cloudflare Workers/package deployments only

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
- `nixbot tf-dns|tf-platform|tf-apps`: runs the phase-specific OpenTofu projects
  locally or through the bastion-trigger path used by `nixbot`. Project
  discovery is suffix-based, so future `tf/<provider>-dns`,
  `tf/<provider>-platform`, and `tf/<provider>-apps` projects participate
  automatically.
- `.github/workflows/nixbot.yaml`: can dispatch the same bastion-based
  build/deploy flow and the standard Terraform phase actions only; it does not
  expose per-project `tf/<project>` actions.
- Terraform credentials can be stored as repo-managed age secrets under
  `data/secrets/cloudflare/*.key.age`; the phase-specific OpenTofu actions
  decrypt them on demand using the existing bastion age key.

## Deploy Ordering

- `nixbot run` runs Cloudflare in phases: `tf-dns`, `tf-platform`, host
  build/deploy, then `tf-apps`.
- `nixbot tf` runs the Terraform phases only: `tf-dns`, `tf-platform`, then
  `tf-apps`.
- `hosts/nixbot.nix` may declare per-host `deps = [ ... ];` for build/deploy
  ordering.
- All selected hosts are built before deploy starts.
- Build parallelism: `NIXBOT_BUILD_JOBS` / `--build-jobs`.
- Deploy parallelism: `NIXBOT_JOBS` / `--deploy-jobs`.
- `NIXBOT_BASTION_FIRST` / `--bastion-first` prioritizes the bastion host first
  for both build ordering and deploy waves when selected.
- Deploy derives dependency waves from `deps`.

## Linting

- `nix fmt` applies the repo formatter configured in `treefmt.toml`.
- `nix run path:.#lint -- deps` verifies the runnable lint wrapper and its
  runtime commands, matching the action-style entrypoints used by `nixbot`.
- `nix run path:.#lint` runs the shared lint suite across the whole repo.
- `nix run path:.#lint -- fix` applies best-effort auto-fixes, then re-runs the
  lint suite to show anything still requiring manual changes.
- `nix run path:.#lint -- --diff` restricts file-scoped checks to changed files.
- `nix run path:.#lint -- fix --diff` applies the same best-effort auto-fixes,
  but only to changed files before re-running the diff-scoped lint checks.
- Repo-wide gates today: read-only formatter checks (`alejandra --check`,
  `deno fmt --check`, and `tofu fmt -check -write=false`) plus `actionlint` and
  `tflint` for `tf/*-*` projects, alongside full-repo `statix`, `deadnix`,
  `shellcheck`, and `markdownlint-cli2` under `.#lint`.
- `lint fix` currently auto-runs `treefmt`, `statix fix`,
  `markdownlint-cli2 --fix`, and `tflint --fix`; `deadnix`, `shellcheck`, and
  `actionlint` remain report-only.
- `lint --diff` keeps the incremental mode for `statix`, `deadnix`,
  `shellcheck`, and `markdownlint-cli2`, which protects new edits with faster
  local feedback.
- `lint fix --diff` uses the same diff file selection as `lint --diff` for
  fix-capable tools, while `tflint --fix` still runs per tracked `tf/*-*`
  project directory.
- CI now warms lint through `nix run path:.#lint -- deps`, which follows the
  same action-command pattern as `nixbot` instead of using a separate
  `.#lint-deps` package.
- When `CI` is set, `nix run path:.#lint` defaults to `--diff` unless you pass
  an explicit scope such as `--full`.
- `./scripts/git-install-hooks.sh` configures Git to use `.githooks/`; the repo
  pre-commit hook runs `nix run path:.#lint -- --diff` before allowing a commit.
