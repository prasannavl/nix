# Stale Cargo Target After Nix GC 2026-09

## Symptom

`cargo check`, `cargo clippy`, or the pre-push diff lint fail while building a
dependency's build script, even though the build-script binary exists on disk:

```text
error: failed to run custom build command for `ring v0.17.14`
  could not execute process `.../target/debug/build/ring-.../build-script-build` (never executed)
  No such file or directory (os error 2)
```

`cargo -v` reports `Dirty <crate>: the env variable CC changed` and then tries
to run the existing build script instead of rebuilding it. Running that binary
directly prints `cannot execute: required file not found`.

## Root cause

Cached `target/debug/build/*/build-script-build` binaries are linked against Nix
store paths (for example `/nix/store/...-glibc-2.40-224/...`) that a later
`nix-collect-garbage` removed. Cargo still considers the build scripts fresh, so
it executes an ELF whose interpreter no longer exists. An incremental
`cargo clean -p <crate>` for one crate only surfaces the next stale crate.

## Fix

Clean the affected crates, or the whole target, then rebuild:

```bash
cargo clean -p <crate> [ -p <crate> ... ]
# or, for a broadly stale tree:
cargo clean
```

Find stale build scripts before cleaning by checking each ELF interpreter:

```bash
for f in target/debug/build/*/build-script-build; do
  interp=$(readelf -l "$f" 2>/dev/null | awk -F'[][]' '/interpreter/{print $2; exit}')
  [ -n "$interp" ] && [ ! -e "$interp" ] && echo "stale: $f"
done
```

## Related: lint sandbox temp paths

The pre-push diff lint runs the Rust package tests under a deep `TMPDIR`
(`/tmp/tmp.XXXXXXXXXX`). The native fleet materializes SSH control sockets in a
transport directory beside the repository, and OpenSSH rejects control paths at
or above 108 bytes, so `fleet_native_runtime` anchors its temp roots under a
short `/tmp/nb-*` prefix (`fn tempdir`). Keep new integration tests on that
helper when they exercise SSH control paths so the sandbox check stays
deterministic.
