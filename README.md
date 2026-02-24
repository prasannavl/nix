# NixOS Config

This repo contains my NixOS and Home Manager configuration, organized as small
modules and composed via `flake.nix`.

## Layout

- `flake.nix`: flake inputs and system definition.
- `hosts/<host>/default.nix`: host-specific system definition and module imports.
- `users/pvl/default.nix`: Base user + Home Manager module builder for `pvl`.
- `lib/*.nix`: single-topic NixOS modules imported directly by hosts.
- `overlays/`: custom overlays used by the system.
- `hosts/nixbot.nix`: deploy mapping (plain Nix attrset).
- `data/secrets/default.nix`: agenix recipients map for `*.age` files.

## GitHub Actions Deploy

Workflow: `.github/workflows/nixbot.yaml`.

- Push to `master`: trigger build-only run.
- Manual (`workflow_dispatch`): set `hosts` and optionally deploy.

The workflow is intentionally thin: it only SSHes into the configured bastion host.

## Deployment

High-level architecture:

- GitHub Actions connects to bastion (`pvl-x2`) using a restricted ingress key and forced command (`ssh-gate`).
- Bastion runs `scripts/nixbot-deploy.sh` to build/deploy selected NixOS hosts.
- Deploy SSH key material is stored as age-encrypted secrets in `data/secrets/*.age`, with bootstrap and rotation rules documented in deployment docs.

Deployment-specific architecture, key model, bootstrap flow, rotation procedure,
and operational notes are documented in:

- `docs/deployment.md`

Primary files for deployment are:

- `hosts/nixbot.nix` (deploy target mapping/defaults)
- `scripts/nixbot-deploy.sh` (build/deploy orchestration)
- `lib/nixbot/bastion.nix` (bastion-side nixbot setup)
