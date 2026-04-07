# Root Package Manifest

- Date: 2026-04-07
- Scope: `pkgs/manifest.nix`, `lib/flake/packages.nix`, `lib/flake/apps.nix`,
  `lib/flake/default.nix`

## Decision

Use one manifest in `pkgs/manifest.nix` as the source of truth for:

- root package registration
- the curated `stdPackages` set used by root lint and fmt orchestration
- root flake app exposure for runnable packages

`lib/flake/apps.nix` remains as the final flake-app projection layer, but it no
longer hand-registers package names.

## Shape

- `packageEntries` in `pkgs/manifest.nix` declares the normal root packages by
  stable manifest `id`.
- Root apps default to the manifest `id`.
- Packages that should not be exposed as root apps set `rootApp = false`.
- Rename-only cases use `appName`, for example `cloudflare-apps-deploy`.
- `lib/flake/packages.nix` evaluates that manifest into the package attrset.
- `packages.nix` also derives:
  - `stdPackages`
  - `rootApps`
- `apps.nix` maps `rootApps` into standard flake `apps` entries and merges in
  `lint.apps`.

## Why

- Removes duplicated root registration across `pkgs/manifest.nix`,
  `packages.nix`, and `apps.nix`.
- Keeps package paths and root app exposure rules aligned in one place.
- Preserves the explicit root composition model instead of returning to
  recursive auto-discovery.
- Keeps special cases explicit, such as `cloudflare-apps.deploy` being exposed
  as the root app `cloudflare-apps-deploy`.

## Consequences

- Adding a new normal root package now usually means editing a single manifest
  entry in `pkgs/manifest.nix`.
- Packages exposed as root apps use the package name by default.
- Packages without a desired root app set `rootApp = false`.
- Renamed root apps use `appName` only for the exceptional alias.
- Root lint and fmt behavior still operates on `stdPackages`, but that set is
  now derived from the same manifest-driven package composition.
