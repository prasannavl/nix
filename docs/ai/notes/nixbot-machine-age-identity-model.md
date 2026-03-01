# Nixbot Machine Age Identity Model Switch

- Date: 2026-03-01
- Scope:
  - `scripts/nixbot-deploy.sh`
  - `lib/nixbot/default.nix`
  - `lib/nixbot/bastion.nix`
  - `hosts/nixbot.nix`
  - `data/secrets/default.nix`
  - `data/secrets/machine/*`

## Goal

Switch activation-time agenix decryption to per-machine identities while keeping:
- separate bastion ingress SSH key model,
- shared nixbot deploy SSH key model.

## Implemented Model

- Global host runtime identity path:
  - `/var/lib/nixbot/.age/identity`
- `lib/nixbot/default.nix` now sets:
  - `age.identityPaths = ["/var/lib/nixbot/.age/identity"]`
  - activation/tmpfiles creation for `/var/lib/nixbot/.age`
- `scripts/nixbot-deploy.sh` now supports host config field:
  - `ageIdentityKey`
  - injects this key before deploy activation.
- Host mapping added in `hosts/nixbot.nix`:
  - `hosts.<name>.ageIdentityKey = "data/secrets/machine/<host>.key.age"`
- Added encrypted per-host machine keys:
  - `data/secrets/machine/pvl-a1.key.age`
  - `data/secrets/machine/pvl-x2.key.age`
  - `data/secrets/machine/llmug-rivendell.key.age`
  - plus corresponding `.pub` recipients.

## Bastion Adjustment

- Reverted bastion key materialization to normal agenix-managed `age.secrets.*` for:
  - `/var/lib/nixbot/.ssh/id_ed25519`
  - `/var/lib/nixbot/.ssh/id_ed25519_legacy`
- Removed manual decrypt loop from bastion activation script.
- Bootstrap loop is avoided because `age.identityPaths` no longer points at `/var/lib/nixbot/.ssh/*`.

## Validation

- `bash -n scripts/nixbot-deploy.sh` passed.
- `nix eval --json --file data/secrets/default.nix` passed.
- `nix build .#nixosConfigurations.pvl-x2.config.system.build.toplevel --no-link -L` passed.

## Rotation Policy

- Machine age identity rotation defaults to single-step replace (no legacy path) because deploy injects identity before activation.
- Legacy overlap is optional and intended only for unusual partial/out-of-band activation paths.
