# ext package move

- Date: 2026-04-08
- Scope: `lib/ext`, `overlays/default.nix`, `scripts/update-{vscode,nvidia}.sh`,
  `README.md`

## Decision

Move the standalone derivation definitions from `pkgs/ext` to `lib/ext`.

## Notes

- These files are not root-flake packages in `pkgs/manifest.nix`; they are
  helper derivations consumed directly by overlays and maintenance scripts.
- Direct repo references should use `lib/ext/*` after the move.
