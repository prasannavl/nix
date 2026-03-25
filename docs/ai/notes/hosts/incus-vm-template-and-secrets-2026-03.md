# Incus VM Template And Secrets (2026-03)

## Scope

Canonical summary of the current reusable Incus guest model, its secret surface,
and the steps for adding another guest by copying an existing guest pattern.

## Durable model

- The parent host owns Incus guest creation and startup.
- Guests start from the reusable `lib/images/incus-base.nix` image.
- Guest-specific real configuration still lives under `hosts/<name>/`.
- `nixbot` deploy then switches the guest to that real configuration.
- Requested guest deploys should expand to include their declared parent-host
  dependency first, so selecting a guest also brings in the host that creates
  and starts it.

## Naming conventions

- **Shared guest module**: `lib/incus-vm.nix` -- uses `vm` to match guest
  terminology across documentation and imports. Previously named
  `lib/incus-machine.nix`; all in-repo imports and doc references were updated
  in the same rename change.
- **Reusable base image**: `lib/images/incus-base.nix` -- uses `base`
  consistently for the module, exported image key, and local Incus image alias.
  Previously named with a `bootstrap` prefix; the rename only affected the
  reusable starting image, not guest-specific configuration terminology.

## Secret model

- No separate Incus-only secret system currently exists.
- Incus guests use the normal host machine identity:
  - `data/secrets/machine/<host>.key.age`
- Optional shared guest helper secret:
  - `data/secrets/tailscale/<host>.key.age`
  - consumed by `lib/incus-vm.nix` when present
- Tailscale auth wiring lives in the shared `lib/incus-vm.nix` module, not in ad
  hoc per-guest host code.
- The stored secret is an OAuth client secret used to mint fresh tagged login
  keys at `tailscale up` time, not a pre-minted reusable auth key.
- The shared module should keep the Tailscale block self-contained: discover the
  encrypted secret path locally, gate it with `builtins.pathExists`, and only
  wire `services.tailscale` when the encrypted file exists.
- The reusable `lib/profiles/systemd-container.nix` base profile should not
  enable Tailscale unconditionally; optional guest Tailscale belongs entirely to
  `lib/incus-vm.nix`.
- Persistent server semantics should keep `ephemeral = false`,
  `preauthorized = true`, and explicit advertised tags such as `tag:vm`.
- Persistent SSH host keys live at `/var/lib/machine/*`, but those are generated
  runtime state, not repo-managed agenix secrets.

## Template steps for a new guest

1. Add `hosts/<name>/default.nix` with `systemd-container` and
   `lib/incus-vm.nix`.
2. Register `<name>` in `hosts/default.nix`.
3. Add an entry for `<name>` in `hosts/<parent-host>/incus.nix`.
4. Add a deploy target entry in `hosts/nixbot.nix`.
5. Add machine identity secret files and recipients.
6. Optionally add Tailscale auth secret and recipients.
7. Re-encrypt `data/secrets`.
8. Deploy the parent host so the guest is created and started.
9. Deploy the guest itself so it transitions from bootstrap image to real host
   config.

## Workload-specific overrides

- Guest workloads must match the parent host's actual hardware model rather than
  inheriting unrelated defaults from other hosts.
- For an AMD-backed GPU guest, the durable model is `/dev/dri` and `/dev/kfd`
  passthrough plus `video` and `render` group access; NVIDIA-specific runtime
  assumptions do not belong in that guest.

## Superseded notes

- `docs/ai/notes/hosts/incus-bootstrap-deploy-flow-2026-03.md`
- `docs/ai/notes/hosts/incus-guest-tailscale-login-2026-03.md`
- `docs/ai/notes/hosts/incus-machine-tailscale-block-refactor-2026-03.md`
- `docs/ai/notes/hosts/incus-guest-ollama-amd-gpu-2026-03.md`
- `docs/ai/notes/hosts/incus-base-image-rename-2026-03.md`
- `docs/ai/notes/hosts/incus-vm-module-rename-2026-03.md`

## Source of truth files

- `hosts/<parent-host>/incus.nix`
- `hosts/<guest>/default.nix`
- `hosts/nixbot.nix`
- `lib/incus-vm.nix`
- `lib/images/incus-base.nix`
- `lib/images/default.nix`
- `docs/incus-vms.md`
- `docs/deployment.md`
