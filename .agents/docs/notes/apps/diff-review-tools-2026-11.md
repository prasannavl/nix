# Diff and review CLIs on the pvl hosts

The three main pvl hosts now get four diff/review tools from the existing shared
package list:

- `delta` 0.19.2 from nixpkgs.
- `difftastic` 0.69.0 from nixpkgs.
- `oyo` 0.1.72 (`oy`), packaged in `lib/ext/oyo`.
- `diffx` 0.7.1, packaged in `lib/ext/diffx`.

`hosts/common/pvl.nix` is imported by pvl-a1, pvl-l5 and pvl-x2. The container
hosts are intentionally excluded.

## Prebuilt packages

Neither `oyo` nor `diffx` is in nixpkgs and neither publishes a binary cache.
Both use the prebuilt GitHub release archives, so the hosts do not compile
Rust/TUI dependency trees:

- `lib/ext/oyo`: release archive `oy-<target>.tar.gz`, wrapped with `oy`'s
  runtime tools (`git`, `jujutsu`, `curl`, `gh`, `glab`, `fzf`, clipboard
  helpers and `xdg-utils`). Supports x86_64 and aarch64 Linux.
- `lib/ext/diffx`: release archive `diffx-<target>.tar.gz`. Upstream ships only
  x86_64 Linux, which covers these pvl hosts.

`lib/overlays/default.nix` exposes both attributes. `sources.nix` in each unit
pins the release version and SRI hashes; there is no updater yet.

## Validation

- `nix build` of `oyo` and `diffx`; `oy --version` reports 0.1.72 and
  `diffx --version` reports 0.7.1 through the packaged binaries.
- `oyo`'s wrapper contains the runtime `PATH` suffix; `autoPatchelfHook`
  resolves the release binaries against Nix glibc, libgcc and zlib.
- `nix eval` of pvl-a1 and pvl-x2 `environment.systemPackages` contains `delta`,
  `difftastic`, `oyo` and `diffx`.
- `nix run .#lint` passes after the host package wiring.
