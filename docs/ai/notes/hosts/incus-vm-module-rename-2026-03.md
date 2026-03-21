# Incus VM Module Rename (2026-03)

## Scope

Rename the shared Incus guest bootstrap module from `lib/incus-machine.nix` to
`lib/incus-vm.nix`.

## Decision

- Use `vm` consistently in the shared module name to match existing
  documentation and guest terminology.
- Update all in-repo imports and durable documentation references to the new
  path in the same change.

## Source of truth files

- `lib/incus-vm.nix`
- `lib/images/incus-base.nix`
- `hosts/llmug-rivendell/default.nix`
- `docs/incus-vms.md`
- `docs/deployment.md`
