# Nixbot Bastion Key Model Update

Date: 2026-02-25

## Final Direction
- Bastion ingress key (`bastionSshKey`) is forced-command-only.
- Regular `nixbot` SSH key (`sshKey`) stays a normal shell key.
- `lib/nixbot/bastion.nix` should not `mkForce` override base nixbot key setup.

## Effective Wiring
- `lib/nixbot/default.nix` provides normal `userdata.sshKey` for `nixbot`.
- `lib/nixbot/bastion.nix` adds only forced-command bastion key entry.
- Net effect: one forced-command key + one normal key.
