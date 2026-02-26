# Nixbot Key Rotation: Overlap + Bastion-First Cutover

Date: 2026-02-26

## User Request
- Make nixbot key handling overlap-capable.
- Provide an operational path to rotate bastion in one pass while retaining old deploy private key only for old nodes in phase 2.

## Implementation Summary
- Added list-based key support in `users/userdata.nix`:
  - `nixbot.sshKeys`
  - `nixbot.bastionSshKeys`
- Kept backward-compatible aliases:
  - `nixbot.sshKey`
  - `nixbot.bastionSshKey`
- Updated modules:
  - `lib/nixbot/default.nix` now installs all keys from `sshKeys`.
  - `lib/nixbot/bastion.nix` now installs all forced-command keys from `bastionSshKeys`.
- Updated age recipients map:
  - `data/secrets/default.nix` now includes all `nixbot.sshKeys` recipients.

## Rotation Path Added
- Documented in `docs/deployment.md`:
  - planned overlap rotation runbook
  - bastion-first single-pass cutover using per-host legacy deploy key overrides in `hosts/nixbot.nix`
