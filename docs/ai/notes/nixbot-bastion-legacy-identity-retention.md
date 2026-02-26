# Nixbot Bastion: Retain Legacy SSH Identity During Key Rotation

## Context
- Requirement: when bastion `/var/lib/nixbot/.ssh/id_ed25519` rotates, keep legacy private key available and have SSH try it as fallback.

## Changes
- `scripts/nixbot-deploy.sh` (`inject_bootstrap_nixbot_key`):
  - before replacing `/var/lib/nixbot/.ssh/id_ed25519`, copy existing key to `/var/lib/nixbot/.ssh/id_ed25519_legacy`.
- `lib/nixbot/bastion.nix`:
  - installs `/var/lib/nixbot/.ssh/config` for user `nixbot` with identity order:
    - `/var/lib/nixbot/.ssh/id_ed25519`
    - `/var/lib/nixbot/.ssh/id_ed25519_legacy`
  - optional agenix secret `nixbot-ssh-key-legacy` from `data/secrets/nixbot-legacy.key.age` when present.
  - `age.identityPaths` includes legacy identity path when legacy key exists.

## Intended Effect
- Bastion keeps a legacy private key path during overlap windows.
- SSH authentication from bastion can fall back to legacy key when targets have not yet trusted the new key.
