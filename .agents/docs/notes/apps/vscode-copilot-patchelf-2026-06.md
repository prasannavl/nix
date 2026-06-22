# VS Code Copilot Patchelf Dependencies 2026-06

## Context

`pvl-l5` failed to build `vscode-1.125.1` during Home Manager generation because
the upstream VS Code tarball now includes Copilot's native
`@github/copilot/sdk/prebuilds/linux-x64/computer.node` module.

`autoPatchelfHook` found the existing Electron and WebKit dependencies, but the
new native module required additional Linux libraries that were not present in
the inherited `pkgs.unstable.vscode` build inputs:

- `libXtst.so.6`
- `libjpeg.so.8`
- `libpipewire-0.3.so.0`
- `libei.so.1`

## Decision

Keep `lib/ext/vscode/default.nix` as a narrow source/version override of
`pkgs.unstable.vscode`, but extend `buildInputs` on Linux with:

- `pkgs.libxtst`
- `pkgs.libjpeg8.out`
- `pkgs.pipewire`
- `pkgs.libei`

Mirror the same list in `lib/ext/vscode/update.sh` so future VS Code version
updates retain the package fix.

## Validation

Validated on 2026-06-23:

```sh
nix build --no-link --print-out-paths .#nixosConfigurations.pvl-l5.pkgs.vscode-upstream
nix build --no-link --print-out-paths .#nixosConfigurations.pvl-l5.config.system.build.toplevel
```

The focused VS Code build produced
`/nix/store/3108k5v6rk6kn1v81kkm3q8d5bqzqai8-vscode-1.125.1`.

The full `pvl-l5` toplevel build produced
`/nix/store/ncl9xg529mpjsjmsyj2bhq87a07p83h2-nixos-system-pvl-l5-26.05.20260618.e8210c6`.
