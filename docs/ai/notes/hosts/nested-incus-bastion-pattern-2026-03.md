# Nested Incus Bastion Pattern (2026-03)

## Scope

New nested Incus bastion guest on a parent Incus host. The nested host also runs
Podman services (`nginx`, `ollama`, `open-webui`) with GPU passthrough for local
LLM inference and manages an inner guest for validation.

## Design decisions

- **Storage driver**: inner incus uses `dir` (not btrfs) to avoid
  btrfs-on-btrfs. The parent host's Incus pool is btrfs-backed; nesting btrfs
  inside btrfs causes performance and stability issues.
- **Subnet**: inner incus bridge uses `10.10.30.0/24` to avoid conflict with the
  outer `10.10.20.0/24` bridge on the parent host.
- **GPU passthrough**: AMD GPU and `/dev/kfd` are forwarded from the parent host
  through to the nested host. Ollama uses Vulkan for inference. The outer host
  can use an Incus `gpu` device, but the inner nested Incus guest cannot. The
  nested pattern here is to bind-mount `/dev/dri` into the inner guest and
  forward `/dev/kfd` separately. The shared Incus machines module treats `/dev`
  host-path disk devices as existing device trees rather than persistent state
  directories, so it does not tmpfiles-create or GC-delete them.
- **Podman services**: nginx (port 18080), multiple Ollama instances (ports
  21434-21436), and open-webui (port 13000) run as Podman compose stacks under a
  dedicated service user.
- **Inner guest**: the nested guest at `10.10.30.10` runs multiple GPU-backed
  Ollama containers plus Open WebUI for nested GPU validation.

## Source of truth files

- `hosts/<nested-incus-host>/default.nix`
- `hosts/<nested-incus-host>/incus.nix`
- `hosts/<nested-incus-host>/services.nix`
- `hosts/<nested-incus-host>/packages.nix`
- `hosts/<nested-incus-host>/users.nix`
- `hosts/<nested-incus-host>/firewall.nix`
- `hosts/<nested-guest>/default.nix`
- `hosts/<parent-incus-host>/incus.nix` (guest entry + GPU passthrough)
- `hosts/nixbot.nix` (deploy targets)
- `hosts/default.nix` (nixosSystem entries)

## Manual steps required after merge

Per `docs/incus-vms.md` steps 5-9:

1. Generate machine identity secrets for the nested host and nested guest
2. Add recipient mappings in `data/secrets/default.nix`
3. Optionally add Tailscale auth secret
4. Re-encrypt secrets
5. Deploy the parent Incus host (recreates the nested host with GPU devices)
6. Deploy the nested Incus host (switches from bootstrap to real config)
7. Deploy the nested guest (reachable from the nested host)
