# kilo-cli: use the prebuilt extension binary, not the nixpkgs `unstable.kilo` source build

Date: 2026-09-13

## Problem

`environment.systemPackages` referenced the nixpkgs-`unstable` `kilo` package
(7.3.40). Its build is a full source build of the kilo monorepo (kilo-code,
kilo-console, kilo-gateway, ...) and failed on every remote host during pvl-a1's
Nix build:

```console
> building Kilo Console
> $ vite build
> .../kilo-console/node_modules/.bin/vite: /usr/bin/env: bad interpreter
  : No such file or directory
> error: Kilo Console build failed with exit code 126
>   at buildKiloConsole (packages/opencode/script/build.ts:93:29)
> Bun v1.3.13 (Linux x64 baseline)
```

Root cause: `kilo-7.3.40`'s `buildPhase` spawns a sub-process that runs
`vite build` for the console. That sub-process resolves a
`node_modules/.bin/vite` shim whose shebang still resolves through
`#!/usr/bin/env`, which does not exist in the clean Nix build sandbox →
`bad interpreter` → exit 126. Nix's `fixupPhase` can only rewrite shebangs of
files it knows about in the build tree; a spaweed child hitting a `.bin/` shim
that `fixupPhase` didn't rewrite is out of reach, so there is no clean
`overrideAttrs` fix from this repo.

No prebuilt `kilo-7.3.40` was available on `cache.nixos.org` for either
nixos-unstable or nixos-26.05 at the locked `unstable` rev
(`8ce4ef6cb6f871616146b9fe26d2a5ae594e94fe`), so Nix was forced to source-build
it.

## What was already available

The repo already installs the `kilocode.kilo-code` VS Code extension
(`users/pvl/vscode/default.nix`). That extension package ships a prebuilt,
self-contained Bun AOT `kilo` binary at:

```text
<ext>/share/vscode/extensions/kilocode.kilo-code/bin/kilo
```

Verified: `kilo --version` → `7.5.16`, `ldd` shows only glibc, no `RPATH`, no
additional dynamic deps, and its dvc closure contains no `kilo-7.3.40`.

## Fix

1. Added `pkgs/tools/kilo-cli/default.nix` — a minimal `runCommand` that copies
   the extension's `bin/` directory onto PATH under `$out/bin`. The `bin/` dir
   is shipped verbatim so every sibling resource (`bwrap`, `ffmpeg`, the sandbox
   worker `.js` files, `tree-sitter`, `licenses/`) stays accessible to the
   `kilo` binary exactly as it is inside the extension tree.
2. Registered it in `pkgs/manifest.nix` so it's exposed on `pkgs` as `kilo-cli`.
3. Swapped `unstable.kilo` → `kilo-cli` in `hosts/pvl-a1/packages.nix`.

## Validation

- `nix build .#pkgs.x86_64-linux.kilo-cli` — builds clean (2s).
- `kilo --version` from the produced `$out/bin/kilo` — `7.5.16`.
- `nix-store -q --requisites <pvl-a1 toplevel>` — no longer references
  `029vilyirhj7ly1g0yxrjanv4gclmpzv-kilo-7.3.40.drv`.
- No other committed AI package in the pvl-a1 config (`jan`, `claude-code`,
  `llm-agents-pkgs.*`, `unstable.llama-cpp`, `qwen-code`, `pi-coding-agent`,
  `codex`, `opencode`, `github-copilot-cli`) transitively pulls `kilo-7.3.40`;
  only `unstable.kilo` did.
- `alejandra` clean on all touched files.

## Notes

- The nixpkgs `kilo` package may be fixed upstream (or a prebuilt artifact
  published) at a later `unstable` lock. When that happens, `unstable.kilo` (the
  "official" package) could replace `kilo-cli` if preferred for CLI version
  parity with the extension.
- If the kilo-code extension is ever bumped to a version that ships a different
  `bin/` layout, update the `cp -a` target in `pkgs/tools/kilo-cli/default.nix`
  accordingly.
