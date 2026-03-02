# Nixbot Rotation Incident: Legacy Deploy Key Recovery

Date: 2026-02-26

## Issue

- Bastion rotated to new `data/secrets/nixbot/nixbot.key.age` material before
  all downstream hosts trusted the new `nixbot` deploy public key.
- Result: bastion could no longer authenticate to legacy hosts that only trusted
  the old `nixbot` key.

## Recovery Applied

1. Restored overlap public keys in `users/userdata.nix`:
   - old + new `nixbot.sshKeys`
   - old + new `nixbot.bastionSshKeys`
2. Recovered old encrypted deploy key as
   `data/secrets/nixbot/nixbot-legacy.key.age` from previous git revision of
   `data/secrets/nixbot/nixbot.key.age`.
3. Added legacy key recipients mapping in `data/secrets/default.nix`.
4. Added temporary per-host legacy key overrides in `hosts/nixbot.nix` for
   non-bastion nodes:
   - `hosts.pvl-a1.key` and `hosts.pvl-a1.bootstrapKey`
   - `hosts.llmug-rivendell.key` and `hosts.llmug-rivendell.bootstrapKey`

## Next Operational Sequence

- Re-encrypt managed secrets.
- Deploy bastion and legacy nodes using overrides.
- After legacy nodes trust new keys, remove legacy overrides/material and cut
  old pubkeys.
