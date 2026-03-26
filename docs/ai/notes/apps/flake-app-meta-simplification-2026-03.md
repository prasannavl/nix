# Flake app meta and warning cleanup (2026-03)

## Context

`nix flake check` emitted warnings for:

- `unknown flake output 'pkgs'` and `'nixosImages'` — intentional non-standard
  outputs, now filtered in lint.
- `app lacks attribute 'meta'` — all five apps lacked `meta.description`.

## Decisions

### `meta.mainProgram` as the single source of truth

Each package `default.nix` sets `meta.description` and `meta.mainProgram`. This
replaced an earlier `passthru.apps.default` approach that required
self-referencing `let` bindings in every package — more code for no benefit.

- Root `lib/flake/apps.nix` uses a `mkApp` helper that reads `meta.mainProgram`
  and inherits `meta` from the package.
- Sub-flake `flake.nix` files use `pkgs.lib.getExe` (which reads
  `meta.mainProgram`) to build their app entries.
- Binary name and description live in one place: the package's `meta`.

### Non-standard flake outputs

`pkgs` (nested package shapes not supported by standard `packages`) and
`nixosImages` (used by `lib/incus.nix`) are intentional. Added comments in
`flake.nix` and filtered the warnings in `scripts/lint.sh` via process
substitution on stderr.

### Removed dead code

- `lint.nix` `app` (singular) attribute — only `apps.lint` is consumed by the
  flake plumbing.
