# Nixbot Bastion Manual Key Decrypt on Activation

- Date: 2026-03-01
- Scope: `lib/nixbot/bastion.nix`
- Status: superseded by `docs/ai/notes/nixbot-machine-age-identity-model.md`

## Context

- Bastion deploy to `pvl-x2` failed during `agenix` activation because `age.identityPaths` referenced:
  - `/var/lib/nixbot/.ssh/id_ed25519`
  - `/var/lib/nixbot/.ssh/id_ed25519_legacy`
- Those paths were themselves `age.secrets.*.path` outputs, creating a bootstrap loop (identity required to decrypt identity secret).

## Decision (Superseded)

This intermediate direction was replaced in the same session by a machine identity model:
- `age.identityPaths` moved to `/var/lib/nixbot/.age/identity` in the base nixbot module.
- Bastion key files returned to normal `age.secrets.*` management.
- Host machine age identities are now injected pre-activation by `scripts/nixbot-deploy.sh`.

## Implementation

- Added `decrypt_nixbot_key()` helper in activation script.
- Decryption attempts:
  1. `/var/lib/nixbot/.ssh/id_ed25519`
  2. `/var/lib/nixbot/.ssh/id_ed25519_legacy`
- Writes secret atomically via temp file and `install -m 0400 -o nixbot -g nixbot`.
- Primary key always refreshed from `data/secrets/nixbot/nixbot.key.age`.
- Legacy key refreshed only when `data/secrets/nixbot/nixbot-legacy.key.age` exists.

## Verification

- `nix build .#nixosConfigurations.pvl-x2.config.system.build.toplevel --no-link -L` succeeded.
