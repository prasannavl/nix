# VS Code Configuration

## Upstream package model

- A repo-local stable VS Code package is defined in
  `pkgs/ext/vscode-upstream.nix`.
- It sources builds from Microsoft's official stable update endpoint in commit
  form: `https://update.code.visualstudio.com/commit:${rev}/${plat}/stable`.
- The package references `pkgs.unstable.vscode` directly rather than accepting a
  base-package argument from the overlay.
- The overlay exports it as `pkgs.vscode-upstream`.
- Home Manager is wired explicitly:
  `programs.vscode.package = pkgs.vscode-upstream`.

## Pinned hash strategy

- Per-platform app and server artifact hashes are pinned in
  `pkgs/ext/vscode-upstream.nix`.
- The bundled VS Code server is kept on the same Microsoft commit so Remote SSH
  stays aligned with the desktop client build.
- `scripts/update-vscode.sh` refreshes the pinned stable release version,
  revision, artifact names, and hashes by regenerating the package file from a
  template (not line-level patching).

## Go toolchain provisioning

- `users/pvl/vscode/default.nix` enables the `golang.go` extension.
- Development hosts that use this VS Code config must install `pkgs.go`,
  `pkgs.gopls`, and `pkgs.delve` in their package group so the extension can
  find the expected CLI tools through the normal user environment.

## Superseded notes

- `docs/ai/notes/tooling/vscode-external-package-2026-03.md`
- `docs/ai/notes/tooling/vscode-go-binaries-pvl-a1-2026-03.md`
