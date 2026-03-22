# VS Code External Package

## Context

- User wanted to stop using VS Code Insiders and use the main stable release.
- User also wanted the package definition to live in `pkgs/ext/` and be exported
  from the overlay, rather than defining package logic inline in the overlay.

## Decision

- Define `pkgs/ext/vscode-upstream.nix` as a repo-local stable VS Code package
  sourced from Microsoft's official stable update endpoint in commit form,
  `https://update.code.visualstudio.com/commit:${rev}/${plat}/stable`, with
  pinned hashes.
- Export that package from the overlay as `pkgs.vscode-upstream`.
- Reference `pkgs.unstable.vscode` directly inside the package file instead of
  passing a separate base-package argument from the overlay.
- Keep the bundled VS Code server on the same Microsoft commit so Remote SSH
  stays aligned with the desktop client build.
- Wire Home Manager explicitly with
  `programs.vscode.package = pkgs.vscode-upstream`.
- Provide `scripts/update-vscode.sh` to refresh the pinned stable release
  version, revision, per-platform app/server artifact names and hashes, and to
  regenerate `pkgs/ext/vscode-upstream.nix` structurally from a template instead
  of patching individual lines in place.
