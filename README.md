# Nix

This is the nix driven monorepo, organized as small modules and composed via
`flake.nix`.

## Layout

- `flake.nix`: flake inputs and system definition.
- `pkgs/`: repo-local runnable source trees; each package owns its own flake and
  is aggregated into a custom top-level flake attr such as
  `.#pkgs.<system>.example-hello-rust`, `.#pkgs.<system>.cloudflare-apps`,
  `.#pkgs.<system>.cloudflare-apps.deploy`, or
  `.#pkgs.<system>.cloudflare-apps.llmug-hello.wrangler-deploy`.
- `pkgs/examples/`: example packages used as reference implementations and test
  beds for package patterns.
- `lib/ext/`: standalone derivation definitions consumed by overlays and helper
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

## Services

The repo has three service models, each documented in detail under `docs/`.

### Native Services (`docs/services.md`)

The default model for turning repo packages into system services. Stick to the
simplest native Linux patterns:

- Package lives in a package-local `default.nix` under `pkgs/`.
- Package-local `flake.nix` exports a `nixosModules` entry.
- Host enables the service with `services.<name>.enable = true`.
- The module defines plain `systemd.services` and, when scheduled,
  `systemd.timers`.
- No repo-specific service abstraction — NixOS modules plus systemd units are
  the framework.

Reference example: `pkgs/examples/hello-rust/flake.nix`.

### Podman Compose (`docs/podman-compose.md`)

Container workloads run as rootless Podman compose stacks managed by a shared
NixOS module:

- Shared Podman base config lives in `lib/podman.nix`.
- Shared compose lifecycle logic lives in `lib/podman-compose/default.nix` with
  shared shell logic in `lib/podman-compose/helper.sh`.
- Deploy-time user-manager orchestration lives in
  `lib/systemd-user-manager/default.nix` with shared shell logic in
  `lib/systemd-user-manager/helper.sh` (documented in
  `docs/systemd-user-manager.md`).
- Hosts declare stacks under `services.podmanCompose.<stack>` in
  `hosts/<host>/services.nix`.
- Compose content can be a Nix attrset, inline YAML, a file path, or a staged
  directory tree.
- Lifecycle tags (`bootTag`, `recreateTag`, `imageTag`) drive deploy-time
  actions such as restart, force-recreate, and image pull.
- `exposedPorts` metadata auto-derives firewall rules, nginx reverse-proxy
  config, and Cloudflare Tunnel ingress.
- Secrets are injected via file-backed `envSecrets`.

### Incus Guests (`docs/incus-vms.md`)

VM and container guests run under Incus with a shared declarative lifecycle
module:

- Parent host orchestration lives in `hosts/<parent-host>/incus.nix`.
- Shared lifecycle logic lives in `lib/incus/default.nix`.
- Reusable guest bootstrap lives in `lib/incus-vm.nix`.
- Base image build lives in `lib/images/incus-base.nix`.
- Guests are declared under `services.incusMachines.instances.<name>`.
- Machines can use the shared default image or point at per-machine image
  overrides.
- Lifecycle tags (`bootTag`, `recreateTag`, `imageTag`) control guest
  stop/start, delete/recreate, and declared image re-import.
- Config-hash changes and non-disk device changes trigger automatic guest
  recreate; disk devices sync in place.
- After bootstrap, guests become normal `nixbot` deploy targets.

### Guiding Principle

Prefer the native operating model of each tool — systemd for services, Podman
for container workloads, Incus for guests — and define consistent patterns and
naming conventions on top rather than inventing repo-specific abstractions.

## Hosts (`docs/hosts.md`)

This repo manages NixOS hosts **agnostic of where they run**. A host can be a
physical machine, a VM on any hosted provider (GCP, AWS, Hetzner, etc), an Incus
container on a local server, laptop, edge device or anything that boots NixOS.
The repo does not encode provider-specific logic at the host level — all hosts
are first-class citizens regardless of their backing infrastructure.

- Each host is a directory under `hosts/<host-name>/` with a `default.nix` entry
  point that imports the appropriate profile and host-specific modules.
- Profiles under `lib/profiles/` provide layered baselines (`core.nix` for
  headless, `all.nix` for desktop, `systemd-container.nix` for Incus guests).
- Device modules under `lib/devices/` encode physical hardware quirks.
- `hosts/default.nix` registers every host into `nixosConfigurations`.
- `hosts/nixbot.nix` maps deploy targets, SSH routing, and ordering.
- The same deploy flow, secret model, and module composition apply whether the
  target is a laptop, a cloud VM, or a nested Incus container.

## GitHub Actions Deploy

Workflow: `.github/workflows/nixbot.yaml`.

- Push to `master`: trigger build-only run.
- Manual (`workflow_dispatch`): set `hosts` and optionally deploy.

The workflow is intentionally thin: it only SSHes into the configured bastion
host via the packaged `nixbot` entrypoint with `--bastion-trigger`.

Security note: deploy does **not** SCP/upload a script to bastion at runtime.
The bastion forced-command key is restricted directly to the packaged `nixbot`
command from `pkgs/tools/nixbot`, so CI/local trigger only invokes that allowed
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
- `pkgs/tools/nixbot/` (canonical packaged nixbot source)
- `nixbot` (packaged deployment entrypoint)
- `pkgs/tools/nixbot/flake.nix` (packaged nixbot application wrapper)
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

- Package-local flakes under `pkgs/` conventionally expose: `checks.lint`,
  `checks.fmt`, `checks.test`, `apps.lint-fix`, `apps.fmt`, and `apps.dev` when
  the package has a runnable dev workflow.
- `checks.*` are read-only verification outputs; mutating actions belong in
  `apps.*`.
- Standard package actions are: `run` to execute the package, `dev` for
  interactive developer workflows, `fmt` to mutate package-owned formatting,
  `lint-fix` to apply safe package-owned auto-fixes, and `checks.fmt` /
  `checks.lint` / `checks.test` for read-only verification.
- `nix fmt` formats root-managed files outside `pkgs/` through the root
  `treefmt` configuration, then runs package-managed formatting through the root
  aggregate package-ops manifest.
- `nix run path:.#lint` lints root-managed files outside `pkgs/`, then runs
  package verification through the root aggregate package-ops manifest for
  `checks.fmt`, `checks.lint`, and `checks.test`.
- `nix run path:.#lint -- fix` applies root-owned formatting and fix-capable
  linting outside `pkgs/`, runs package-local `fmt` and `lint-fix` actions
  through the root aggregate package-ops manifest, then re-runs lint to show
  anything still requiring manual changes.
- `nix run path:.#lint -- --project <name>` and
  `nix run path:.#fmt -- --project <name>` restrict package work to one or more
  selected child flakes by directory name under `pkgs/`.
- Common package commands are: `nix build ./pkgs/<name>`,
  `nix run ./pkgs/<name>`, `nix run ./pkgs/<name>#dev`,
  `nix run ./pkgs/<name>#fmt`, `nix run ./pkgs/<name>#lint-fix`,
  `nix build ./pkgs/<name>#checks.fmt`, `nix build ./pkgs/<name>#checks.lint`,
  `nix build ./pkgs/<name>#checks.test`, and `nix flake check ./pkgs/<name>`.
- Root-owned formatter policy outside `pkgs/` is intentionally narrow:
  Markdown/JSON/JSONC via `deno fmt`, Nix via `alejandra`, Terraform/OpenTofu
  via `tofu fmt`, and shell via `shfmt`.
- Package-local language policy is defined in shared flake helpers rather than
  per-project shell snippets: Rust uses `rustfmt`/`clippy`/`cargo test`, Python
  uses `ruff`, Go uses `gofmt`/`go vet`/`go test`, and web projects use `biome`.
- Repo-wide root lint gates include read-only formatter checks
  (`alejandra --check`, `deno fmt --check`, `tofu fmt -check -write=false`, and
  `shfmt -d`), plus `statix`, `deadnix`, `shellcheck`, `markdownlint-cli2`,
  `actionlint`, and `tflint`.
- `nix run path:.#lint -- deps` verifies the runnable lint wrapper and its
  runtime commands, matching the action-style entrypoints used by `nixbot`.
- `nix run path:.#lint -- --diff` restricts file-scoped root checks to changed
  files and only runs full child-flake checks on changed packages.
- `nix run path:.#lint -- fix --diff` applies the same best-effort auto-fixes,
  but only to changed files before re-running the diff-scoped lint checks.
- CI now warms lint through `nix run path:.#lint -- deps`, which follows the
  same action-command pattern as `nixbot` instead of using a separate
  `.#lint-deps` package.
- When `CI` is set, `nix run path:.#lint` defaults to `--diff` unless you pass
  an explicit scope such as `--full`.
- `./scripts/git-install-hooks.sh` configures Git to use `.githooks/`; the repo
  pre-commit hook runs `nix run path:.#lint -- --diff` before allowing a commit.

## Package Helper

The child-flake helper contract is documented in
[`docs/flake-package.md`](./docs/flake-package.md).
