# gap3 package layout move

- Date: 2026-04-08
- Scope: `pkgs/{manifest.nix,README.md}`, `pkgs/web/gap3-hello`,
  `pkgs/srv/ingest`, `hosts/gap3-rivendell/services.nix`, `docs/nginx-vhosts.md`

## Decision

Move the current gap3 app packages into grouped subdirectories under `pkgs/`,
while keeping the root flake package and app IDs flat:

- `pkgs/gap3-ai-web` -> `pkgs/web/gap3-hello`
- `pkgs/gap3-api-ingest` -> `pkgs/srv/ingest`
- root flake ID `gap3-ai-web` -> `web-gap3-hello`
- root flake ID `gap3-api-ingest` -> `srv-ingest`

## Notes

- The nested package move requires child flakes and package definitions to walk
  up one additional directory when importing `lib/flake/pkg-helper.nix`.
- Package-local Nix metadata and package names should match the moved project
  names instead of continuing to expose the legacy `gap3-ai-web` and
  `gap3-api-ingest` names.
- Host and documentation references that call the canonical package directly
  should use the new nested paths.
