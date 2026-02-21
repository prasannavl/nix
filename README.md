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
- `.sops.yaml`: SOPS encryption rules/recipients.

## GitHub Actions Deploy

Workflow: `.github/workflows/nixbot.yaml`.

- Pull requests: build all hosts.
- Push to `main`: build all hosts.
- Manual (`workflow_dispatch`): set `hosts` and optionally deploy.

The workflow is intentionally thin and calls `scripts/nixbot-deploy.sh`.

Runner prerequisite:

- CI must provide `SOPS_AGE_KEY` (for example from GitHub secret `GH_AGE_KEY`).

## Architecture

Deploy auth is split into two layers:

1. GitHub runner decryption key:
   - `hosts/nixbot.nix` is plain Nix data and does not require decryption.
   - Workflow sets `SOPS_AGE_KEY` from GitHub Secrets.
2. Nixbot SSH deploy key:
   - `defaults.key` (or host `key`) points to an encrypted key file (for example `data/secrets/nixbot.key`).
   - `nixbot-deploy.sh` decrypts key files in `data/secrets` in place, uses key file paths with SSH `-i`, then re-encrypts on cleanup.

This means the runner only needs the age private key, while the actual SSH deploy key
stays encrypted at rest in `data/secrets/nixbot.key`.

## Deploy Script

- `scripts/nixbot-deploy.sh`

Examples:

- `scripts/nixbot-deploy.sh --hosts "llmug-rivendell"`
- `scripts/nixbot-deploy.sh --hosts "pvl-a1,llmug-rivendell"`
- `scripts/nixbot-deploy.sh`
- `scripts/nixbot-deploy.sh --hosts "llmug-rivendell" --action build`
- `scripts/nixbot-deploy.sh --hosts "llmug-rivendell" --force`
- `scripts/nixbot-deploy.sh --hosts "llmug-rivendell" --dry`
- `scripts/nixbot-deploy.sh --config hosts/nixbot.nix`

Deploy behavior:

- By default, deploy is skipped per host when built toplevel path matches remote `/run/current-system`.
- Use `--force` to deploy even when unchanged.
- Use `--dry` to print deploy commands and avoid execution.

## Deploy Config

`hosts/nixbot.nix` contains non-secret deploy mapping:

```nix
{
  hosts = {
    pvl-a1 = {
      target = "10.0.0.10";
      user = "root";
      key = "data/secrets/nixbot.key";
    };
  };

  defaults = {
    user = "root";
    key = "data/secrets/nixbot.key";
    knownHosts = "10.0.0.10 ssh-ed25519 AAAA...";
  };
}
```

Notes:

- `target` can be hostname, IP, or `host:port`.
- `key` is a path to a SOPS-encrypted private key file.
- During deploy, the script decrypts secrets in place, uses key file paths directly for SSH, and re-encrypts on cleanup.
- `knownHosts` can be set in `defaults` or per host.

## SOPS Setup

1. Add age recipient(s) in `.sops.yaml` (including the GitHub runner's public age key).
2. Populate `hosts/nixbot.nix`.
3. Create and encrypt deploy key file(s), for example:
   - `sops --encrypt --in-place data/secrets/nixbot.key`
4. In CI, set `SOPS_AGE_KEY` from a GitHub secret that contains the age private key.
