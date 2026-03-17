# OpenSSH Module Centralization

- Date: 2026-03-13
- Scope: `lib/openssh.nix`, `lib/network.nix`,
  `lib/profiles/systemd-container.nix`

## Summary

Extracted the repo's shared `services.openssh.enable = true` wiring into a new
`lib/openssh.nix` module.

## Decisions

- Kept the existing inclusion points intact by importing `lib/openssh.nix` from
  `lib/network.nix` and `lib/profiles/systemd-container.nix`.
- Added an explicit `services.openssh.settings = {};` placeholder so future SSH
  daemon options can be centralized in one module without changing call sites.

## Outcome

- Standard hosts that inherit `lib/network.nix` still enable OpenSSH.
- Container-profile hosts that bypass `lib/network.nix` still enable OpenSSH
  through `lib/profiles/systemd-container.nix`.
