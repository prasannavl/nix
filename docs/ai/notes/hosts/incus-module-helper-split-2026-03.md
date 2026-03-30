# Incus Module Helper Split

**Date**: 2026-03-30

## Summary

Restructure the Incus lifecycle module from the monolithic `lib/incus.nix` file
into `lib/incus/default.nix` and `lib/incus/helper.sh`, matching the repo
pattern already used by `lib/systemd-user-manager/` and `lib/podman-compose/`.

## Key Decisions

- Move shell-heavy runtime logic into `lib/incus/helper.sh` behind one
  `incus-machines-helper` package with subcommands for reconcile, settlement,
  per-machine lifecycle, image import, and GC.
- Keep `lib/incus.nix` as a compatibility shim that imports `./incus`, so old
  references continue to evaluate while hosts migrate to the directory import.
- Preserve the public command names `incus-machines-reconciler` and
  `incus-machines-settlement` via thin wrapper binaries.

## Operational Effect

- Incus module structure now matches the rest of the repo’s helper-backed
  modules.
- Runtime behavior should stay the same; the change is primarily structural and
  intended to make the module easier to maintain.
