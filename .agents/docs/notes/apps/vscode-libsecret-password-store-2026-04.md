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

## Follow-up

- On `pvl-a1`, the active `code` binary resolved through
  `/etc/profiles/per-user/pvl/bin/code`, so Home Manager was active and PATH
  precedence was not the issue.
- The generated wrapper contained Nixpkgs' default `NIXOS_OZONE_WL` Wayland
  flags, but not `--password-store=gnome-libsecret`.
- Root cause: `lib/ext/vscode-upstream.nix` used
  `pkgs.unstable.vscode.overrideAttrs` to replace the upstream source/version,
  while the `commandLineArgs` setting is a function argument to the upstream
  `vscode` package. `overrideAttrs` cannot change that argument, and the local
  wrapper function did not accept or forward it.
- Fix: accept `commandLineArgs` in `lib/ext/vscode-upstream.nix` and first call
  `pkgs.unstable.vscode.override { commandLineArgs = commandLineArgs; }`, then
  apply the source/version `overrideAttrs`.
