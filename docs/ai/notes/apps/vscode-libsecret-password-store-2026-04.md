# VS Code Libsecret Password Store

## Context

- User asked to make `code` always launch with libsecret as password store.
- Repo-owned `pkgs.vscode-upstream` tracks upstream stable Code and was already
  used by `users/pvl/vscode/default.nix`.

## Decision

- `lib/ext/vscode-upstream.nix` exposes Nixpkgs VS Code `commandLineArgs`.
- `users/pvl/vscode/default.nix` overrides `pkgs.vscode-upstream` with
  `--password-store=gnome-libsecret`.
- Extensions stay keyed to the overridden package version so extension release
  alignment remains tied to the actual Code package.
