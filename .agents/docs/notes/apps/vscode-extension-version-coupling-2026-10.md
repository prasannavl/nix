# VS Code Extension / Pin Version Coupling 2026-10

## Context

After `flake.lock` refreshed `nix-vscode-extensions`, the `pvl-a1` build-plan
evaluation failed:

```text
error: attribute 'vscode-pull-request-github' missing
at users/pvl/vscode/default.nix:30:11
```

`users/pvl/vscode/default.nix` selects extensions with
`pkgs.nix-vscode-extensions.forVSCodeVersion v`, where `v` is the pinned
`pkgs.vscode-upstream.version`.

## Root cause

- `nix-vscode-extensions` caches only the latest release per extension.
- `forVSCodeVersion` drops any extension whose latest release declares a VS Code
  engine newer than the requested version, with no older-version fallback.
- The refreshed data ships `GitHub.vscode-pull-request-github` `0.168.0` with
  engine `^1.141.0`, while `lib/ext/vscode/sources.nix` still pinned VS Code
  `1.139.1`.

The extension list and the VS Code pin are therefore coupled whenever the
`vscode-ext` input moves.

## Decision

- Bump `lib/ext/vscode/sources.nix` with `lib/ext/vscode/update.sh` so the pin
  covers the engine requirement. Landed `1.141.0`
  (`2a59476c9bfcb90b3ddc372c36762471b7dfad1c`).
- Do not paper over the failure by pinning `nix-vscode-extensions` backwards or
  by silently dropping the extension.
- The updater still mutates only `sources.nix`; `default.nix` keeps the package
  override (Copilot patchelf inputs, ripgrep path, server outputs).

## Maintenance rule

When `flake.lock`/`vscode-ext` is refreshed, re-check the extension list against
the pinned VS Code. A missing `pkgs.nix-vscode-extensions` attribute usually
means "bump the VS Code pin", not "delete the extension".

## Validation

```sh
nix eval --raw .#nixosConfigurations.pvl-a1.config.system.build.toplevel.drvPath
nix build --no-link --print-out-paths .#nixosConfigurations.pvl-a1.pkgs.vscode-upstream
```

Both succeeded on 2026-10-11; the VS Code build produced
`/nix/store/g47b8x1r21f6mvlr0lxh6mj6cagmwsxd-vscode-1.141.0`.
