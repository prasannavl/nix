# kache compiler cache on pvl-a1, pvl-l5 and pvl-x2

On 2026-11-17 the three physical Pvl hosts gained
[kache](https://github.com/kunobi-ninja/kache) v2.1.1 as a compiler cache for
Rust, C/C++ and CUDA. The nested lab hosts (`pvl-vlab`, `pvl-vlab-1`, `pvl-vk`,
`pvl-vk-1`) are unchanged: no Cargo workload of their own.

## Shape

- Settings live per host, `hosts/<host>/services/kache.nix`, registered in that
  host's `services/default.nix` — the dotlink layout. The three files are
  identical apart from the store budget.
- The service module is repo-owned, `lib/services/kache/default.nix` (`enable`,
  `package`, `rustcWrapper`, `daemon.enable`, freeform `settings`). Upstream's
  module was used first, and dropped together with the flake input: once the
  package comes from `lib/ext`, an input pinned
  `github:kunobi-ninja/kache/v2.1.1` bought only ~50 lines of wiring while
  dragging its own `nixpkgs` and `rust-overlay` nodes into the lock.
- `pkgs.kache` is a **prebuilt musl release**, not a source build. Upstream's
  own package builds ~460 crates and needs its `rust-overlay` toolchain pin
  (`1.99.1`) because pinned nixpkgs `rustc` is `1.95.0`, exactly the crate's
  MSRV. That is minutes of build per version bump for a pinned CLI, so the
  release archive is packaged instead.
- The unit follows upstream (pinned tag, no patch, no repo-owned build logic),
  so it lives in `lib/ext/kache/` and is exposed from the shared overlay block
  in `overlays/default.nix` — per
  [external source units](../../../.agents/docs/design-patterns/external-source-units.md).
  `pkgs/ext/` is for units this repository reshapes.
- `rustcWrapper = true` (module default) sets
  `environment.variables.RUSTC_WRAPPER` to the `kache` binary.
- `daemon.enable = true` runs `kache daemon run` as a systemd **user** service
  (`wantedBy = [ "default.target" ]`), started with the pvl user manager.
- Configuration is declarative only, `/etc/kache/config.toml` plus
  `KACHE_CONFIG`. `settings.cache.local_max_size` is `150GB` on
  `pvl-a1`/`pvl-l5` and `200GB` on `pvl-x2`. All exceed the built-in cap
  deliberately: the default is 5% of the volume clamped to 5–100 GiB
  (`DISK_SHARE_PERCENT`/`_CAP`), about 47 GiB on a 953 GiB root, which would
  evict a Cargo workspace this size. Store path stays `~/.cache/kache`.
- `kache init` is never run: it writes `~/.cargo/config.toml` and `$HOME` shims,
  which would fight the dotlink-managed profiles.

## Where `RUSTC_WRAPPER` reaches

`environment.variables` reaches login shells **and** `nix develop`. A devShell
environment is the derivation environment layered over the _caller's_
environment, so an ambient wrapper survives into the shell even though the
derivation does not set it — verified:

```console
$ RUSTC_WRAPPER=/sentinel/wrapper nix develop --command sh -c 'echo $RUSTC_WRAPPER'
/sentinel/wrapper
```

Plain-shell and devShell `cargo build` therefore hit kache; `nix build` and
`nix flake check` do not, because a builder environment is constructed from the
derivation attrs.

Consequence: `lib/flake/rust/toolchain.nix:validateBuildAttrs` rejects
`RUSTC_WRAPPER` in build attrs, but it inspects attrs only and cannot see a
wrapper inherited from the shell. Certification runs of helper-built artifacts
must drop it explicitly (`env -u RUSTC_WRAPPER cargo …`) or use `nix build`.

## dotlink store sharing

dotlink v0.17.3 has no `kache` member in its `CacheKind` enum (13 kinds;
`sccache` and `ccache` are there), so `DOTLINK_CACHES` cannot express it. The
store is shared with the sandbox through the generic mount instead, next to the
existing abird cache mount:

```nix
DOTLINK_MOUNTS = lib.concatStringsSep "," [
  "/home/pvl/.cache/abird:/tmp/home/.cache/abird:rw"
  "/home/pvl/.cache/kache:/tmp/home/.cache/kache:rw"
];
```

`DOTLINK_MOUNTS` is a comma-separated `SOURCE:TARGET[:ro|rw]` list
(`src/setup.rs:env_mount_grants`). A tmpfiles rule creates the host directory so
the mount source exists before kache's first run. kache's `runtime_dir` defaults
to the cache dir (`crates/kache-config/src/config.rs`), so the sandbox reaches
the store but not the host daemon socket — sandboxed builds run kache directly.

Adding `CacheKind::Kache` to dotlink would drop the mount and give discovery for
free; that belongs in the dotlink repository, not here.

## Rejected: source build

Tried first, and dropped. Upstream's package ran 5488 tests with `doCheck` on;
three builds on 2026-11-17 failed twice in
`build_script::tests::the_launcher_passes_every_variable_name_on`. That test
prints a child's environment and unwraps `String::from_utf8`, while a sibling
test sets a non-UTF-8 `DEP_*` value through `std::env::set_var` — process
global, so the child inherits it:

```text
DEP_KT_BINARY_METADATA=metadata-\xfe
```

Serialising the suite (`cargoTestFlags ++ [ "--" "--test-threads=1" ]`) removes
the race — 138 s versus 37 s parallel — but the 463-crate compile it sits on top
of is what actually costs the time. The prebuilt archive sidesteps build and
tests both.

## Verification

- `nix flake lock` added `kache` plus a second `rust-overlay` node. `dotlink`
  already pinned one; both follow repo `nixpkgs`, so the duplicate is two revs
  of the same overlay, not two nixpkgs. Pure (non-`--impure`) eval resolves the
  host, so deploy paths are unaffected.
- `nix eval --json --file lib/ext/kache/sources.nix` reports the record.
- `pkgs.kache` builds in seconds: `kache 2.1.1` with `kache-engine`, `kache-cl`,
  `kache-clang-cl` and the `$out/shims` farm.
- Wrapper probe on pvl-l5 with a scratch crate, through the packaged path: cold
  `cargo build`, then `cargo clean` and a second build —
  `kache stats
  --last-build` reports 1 of 2 crates from cache.
- `nix eval` of `system.build.toplevel.drvPath` for `pvl-a1`, `pvl-l5` and
  `pvl-x2`, one host at a time: all three succeed with
  `RUSTC_WRAPPER = <kache>/bin/kache`, the user unit and
  `/etc/kache/config.toml`.
- `nix fmt` clean; `nix run .#lint` passes.
- Nothing deployed yet.
