# gap3-gondor Incus-Inside-Incus Bastion (2026-03)

## Scope

New incus guest `gap3-gondor` on pvl-x2 that itself runs incus, serving as a
bastion host for another org/repo. Also runs podman services (nginx, ollama,
open-webui) with GPU passthrough for local LLM inference. Manages inner guest
`gap3-rivendell`.

## Design decisions

- **Storage driver**: inner incus uses `dir` (not btrfs) to avoid
  btrfs-on-btrfs. The outer pvl-x2 incus pool is btrfs-backed; nesting btrfs
  inside btrfs causes performance and stability issues.
- **Subnet**: inner incus bridge uses `10.10.30.0/24` to avoid conflict with the
  outer `10.10.20.0/24` bridge on pvl-x2.
- **GPU passthrough**: AMD GPU and `/dev/kfd` forwarded from pvl-x2 through to
  the guest (same pattern as llmug-rivendell). Ollama uses Vulkan for inference.
  The outer host can use an Incus `gpu` device, but the inner nested Incus guest
  cannot. The nested pattern here is to bind-mount `/dev/dri` into the inner
  guest and forward `/dev/kfd` separately. The shared Incus machines module
  treats `/dev` host-path disk devices as existing device trees rather than
  persistent state directories, so it does not tmpfiles-create or GC-delete
  them.
- **Podman services**: nginx (port 18080), multiple Ollama instances (ports
  21434-21436), and open-webui (port 13000) run as podman compose stacks under
  the `gap3` user.
- **Naming**: `gap3-` prefix; will move to a separate repo later.
- **Inner guest**: `gap3-rivendell` at `10.10.30.10`, runs multiple GPU-backed
  Ollama containers plus Open WebUI for nested GPU validation.

## Source of truth files

- `hosts/gap3-gondor/default.nix`
- `hosts/gap3-gondor/incus.nix`
- `hosts/gap3-gondor/services.nix`
- `hosts/gap3-gondor/packages.nix`
- `hosts/gap3-gondor/users.nix`
- `hosts/gap3-gondor/firewall.nix`
- `hosts/gap3-rivendell/default.nix`
- `hosts/pvl-x2/incus.nix` (guest entry + GPU passthrough)
- `hosts/nixbot.nix` (deploy targets)
- `hosts/default.nix` (nixosSystem entries)

## Manual steps required after merge

Per `docs/incus-vms.md` steps 5-9:

1. Generate machine identity secrets for gap3-gondor and gap3-rivendell
2. Add recipient mappings in `data/secrets/default.nix`
3. Optionally add tailscale auth secret
4. Re-encrypt secrets
5. Deploy pvl-x2 (recreates the guest with GPU devices)
6. Deploy gap3-gondor (switches from bootstrap to real config)
7. Deploy gap3-rivendell (inner guest, reachable from gap3-gondor)
