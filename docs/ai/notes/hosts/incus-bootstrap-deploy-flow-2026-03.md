# Incus Bootstrap Deploy Flow (2026-03)

## Scope

Durable model for Incus guests that bootstrap on the parent host and then
transition to normal `nixbot` host deployment.

## Core design

- Use one reusable bootstrap image from `lib/images/incus-bootstrap.nix`, not a
  guest-specific seed image.
- Use `lib/incus-machine.nix` for shared guest bootstrap concerns: persistent
  host keys under `/var/lib/machine/*` and optional Tailscale auth wiring.
- `hosts/<parent-host>/incus.nix` owns guest creation and first boot.
- The guest's own host definition still owns its real configuration and later
  deploys.

## Deployment rule

- `hosts/nixbot.nix` should target the guest's stable pre-Tailscale reachable
  address when needed, but concrete guest names and IPs should stay in config.
- Requested deploy hosts must expand to include declared dependencies before
  ordering, so selecting an Incus guest implicitly includes the parent host that
  creates and starts it.

## Practical result

- The bootstrap image is reusable for future guests.
- Parent-host activation handles guest existence and startup.
- `nixbot` still treats each guest as a real host after bootstrap.
