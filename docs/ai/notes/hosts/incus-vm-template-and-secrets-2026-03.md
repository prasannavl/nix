# Incus VM Template And Secrets (2026-03)

## Scope

Canonical summary of the current reusable Incus guest model, its secret
surface, and the steps for adding another guest by copying an existing guest
pattern.

## Durable model

- The parent host owns Incus guest creation and startup.
- Guests start from the reusable `lib/images/incus-bootstrap.nix` image.
- Guest-specific real configuration still lives under `hosts/<name>/`.
- `nixbot` deploy then switches the guest to that real configuration.

## Secret model

- No separate Incus-only secret system currently exists.
- Incus guests use the normal host machine identity:
  - `data/secrets/machine/<host>.key.age`
- Optional shared guest helper secret:
  - `data/secrets/tailscale/<host>.key.age`
  - consumed by `lib/incus-machine.nix` when present
- Persistent SSH host keys live at `/var/lib/machine/*`, but those are
  generated runtime state, not repo-managed agenix secrets.

## Template steps for a new guest

1. Add `hosts/<name>/default.nix` with `systemd-container` and
   `lib/incus-machine.nix`.
2. Register `<name>` in `hosts/default.nix`.
3. Add an entry for `<name>` in `hosts/<parent-host>/incus.nix`.
4. Add a deploy target entry in `hosts/nixbot.nix`.
5. Add machine identity secret files and recipients.
6. Optionally add Tailscale auth secret and recipients.
7. Re-encrypt `data/secrets`.
8. Deploy the parent host so the guest is created and started.
9. Deploy the guest itself so it transitions from bootstrap image to real host
   config.

## Source of truth files

- `hosts/<parent-host>/incus.nix`
- `hosts/<guest>/default.nix`
- `hosts/nixbot.nix`
- `lib/incus-machine.nix`
- `lib/images/incus-bootstrap.nix`
- `docs/incus-vms.md`
