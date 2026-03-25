# Lib Broader Review Fixes

## Context

A broader review of `lib/` found three actionable issues outside the earlier
`podman`, `incus`, and `systemd-user-manager` review:

1. `lib/network-wifi.nix` tried to restart NetworkManager through a systemd unit
   wired into the suspend transaction, which did not reliably model a
   post-resume action.
2. `lib/profiles/systemd-container.nix` enabled Tailscale unconditionally,
   weakening the intended optional-guest-Tailscale model owned by
   `lib/incus-vm.nix`.
3. `lib/flatpak.nix` used `grep` in a service script without declaring it in the
   service runtime path.

The timezone choice in `lib/profiles/systemd-container.nix` was intentionally
left unchanged for now.

## Decision

- Switch the Wi-Fi workaround to `powerManagement.resumeCommands`.
- Remove unconditional Tailscale enablement from the reusable systemd-container
  profile.
- Declare `pkgs.gnugrep` in the Flatpak bootstrap service path.

## Implementation

- `lib/network-wifi.nix`
  - dropped `networkmanager-restart-on-suspend`
  - added `powerManagement.resumeCommands` to restart NetworkManager after
    resume
- `lib/profiles/systemd-container.nix`
  - removed `services.tailscale.enable = true`
- `lib/flatpak.nix`
  - added `pkgs.gnugrep` to the service `path`
- `docs/ai/notes/hosts/incus-vm-template-and-secrets-2026-03.md`
  - clarified that optional guest Tailscale belongs in `lib/incus-vm.nix`, not
    the base container profile

## Operational Effect

- The NetworkManager workaround now runs in the correct resume path.
- Incus and other systemd-container guests only enable Tailscale when their
  guest-specific secret wiring is present.
- The Flathub bootstrap service no longer depends on ambient PATH for `grep`.
