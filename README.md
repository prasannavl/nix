# NixOS Config

This repo contains my NixOS and Home Manager configuration, organized as small
modules and composed via `flake.nix`.

## Layout

- `flake.nix`: flake inputs and system definition.
- `hosts/<host>/default.nix`: host-specific system definition and module imports.
- `users/pvl/default.nix`: Base user + Home Manager module builder for `pvl`.
- `lib/*.nix`: single-topic NixOS modules imported directly by hosts.
- `overlays/`: custom overlays used by the system.
- `hosts/nixbot.yaml`: merged deploy mapping + encrypted secret fields.
- `.sops.yaml`: SOPS encryption rules/recipients.

## GitHub Actions Deploy

Workflow: `.github/workflows/nixbot.yml`.

- Pull requests: build all hosts.
- Push to `main`: build all hosts.
- Manual (`workflow_dispatch`): set `hosts` and optionally deploy.

The workflow is intentionally thin and calls `scripts/nixbot-deploy.sh`.

GitHub secret required:

- `SOPS_AGE_KEY`: age private key used by `sops` to decrypt `hosts/nixbot.yaml`.

## Deploy Script

- `scripts/nixbot-deploy.sh`

Examples:

- `scripts/nixbot-deploy.sh --hosts "llmug-rivendell"`
- `scripts/nixbot-deploy.sh --hosts "pvl-a1,llmug-rivendell"`
- `scripts/nixbot-deploy.sh`
- `scripts/nixbot-deploy.sh --hosts "llmug-rivendell" --action build`
- `scripts/nixbot-deploy.sh --hosts "llmug-rivendell" --force`
- `scripts/nixbot-deploy.sh --hosts "llmug-rivendell" --dry`
- `scripts/nixbot-deploy.sh --config hosts/nixbot.yaml`

Deploy behavior:

- By default, deploy is skipped per host when built toplevel path matches remote `/run/current-system`.
- Use `--force` to deploy even when unchanged.
- Use `--dry` to print deploy commands and avoid execution.

## Merged SOPS Config

`hosts/nixbot.yaml` contains both non-secret and secret fields:

```yaml
defaults:
  user: root
  key: |
    -----BEGIN OPENSSH PRIVATE KEY-----
    ...
    -----END OPENSSH PRIVATE KEY-----
  knownHosts: |
    10.0.0.10 ssh-ed25519 AAAA...

hosts:
  pvl-a1:
    target: 10.0.0.10
    user: root
    key: |
      -----BEGIN OPENSSH PRIVATE KEY-----
      ...
      -----END OPENSSH PRIVATE KEY-----
```

Notes:

- `target` can be hostname, IP, or `host:port`.
- `key` is key **content** (not file path); the script materializes temp key files.
- `knownHosts` can be set in `defaults` or per host.

## SOPS Setup

1. Add age recipient(s) in `.sops.yaml`.
2. Populate `hosts/nixbot.yaml`.
3. Encrypt file in-place:
   - `sops --encrypt --in-place hosts/nixbot.yaml`
4. In CI, provide only `SOPS_AGE_KEY`.
