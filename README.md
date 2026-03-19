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
