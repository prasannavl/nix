# Flake Check: `path:` Input Pure Evaluation Fix

## Problem

The lint script ran `nix flake check "path:./${flake_dir}"` from the repo root.
The `path:` URI prefix tells Nix to copy **only** that subdirectory into the
store. Sub-flakes with sibling `path:` inputs (e.g., `cloudflare-apps` depending
on `path:../nixbot`) broke because `../nixbot` resolved to `/nix/store/nixbot` —
an absolute path forbidden by pure evaluation.

## Root Cause

`path:` flake URIs isolate the target directory. Once copied to the store,
relative references to sibling directories escape the store entry. This is a
known Nix limitation for monorepo sub-flakes with cross-directory `path:`
inputs.

## Fix

Changed `scripts/lint.sh` from:

```bash
nix flake check "path:./${flake_dir}"
```

to:

```bash
(cd "${flake_dir}" && nix flake check)
```

Running from inside the directory lets Nix detect the parent `.git` and include
the full repo tree, making sibling `path:` inputs resolvable.

## Scope

- `scripts/lint.sh`: lint invocation change
- `pkgs/cloudflare-apps/default.nix`: restored `nixbot` default for
  `nix-build` compatibility
- `pkgs/cloudflare-apps/flake.nix`: kept `nixbot` as `path:` input with
  `deploy` output
- `tf/modules/cloudflare/scripts/worker-dir-nix-resolver.sh`: improved error
  propagation (stderr instead of stdout JSON, ERR trap, explicit nix build
  failure messages)
