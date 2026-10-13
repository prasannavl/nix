---
type: validation
plan: 2026-w40-rust-fabric-implementation
coordinator: agent:rust-foundation-main
author: agent:rust-foundation-main
timestamp: 2026-10-13T04:42:27.539822+00:00
---

# Optional Cargo implemented; original warm gate passed; next metadata variation

## Optional qualification Cargo implemented — 2026-10-13

Human approved the exact upstream Cargo PR #16691 ordering patch for optional
qualification only. R now provides patched-cargo.nix, cargo-order-check.nix and
manager-patched-vm.nix under scripts/rust-fabric/qualification. The regular VM
route defaults to regular Cargo; no root-flake check or system package enables
the patch. Regular Cargo and manager derivation identities are unchanged.

The real patched Cargo built, and a small independent-compilation/source-edit
regression passed. The full manager matrix reached four successful build,
packaging and version cases. The original forced-warm byte-equality gate now
passes with exactly 2 workspace / 0 external compilations. Changed warm and
independent changed fresh nevertheless differ in cache and package NAR hashes;
full qualification remains incomplete.

A fresh retained comparison found package differences in anonymous LLVM symbol
suffixes/non-allocated symbol-table data. All 29 allocated ELF sections match;
fully stripped diagnostic copies match exactly. The member head also has manager
rmeta/rlib differences, and independently produced parent cache NARs differ. No
runtime-loaded byte difference was observed in this package pair. The exact
generator of the remaining cache/compiler metadata variation is not yet proved.
Diagnostic stripping changed only owned copies; producer outputs, regular
compiler flags, Cargo fingerprints and production packaging stay intact.

Next bounded unit is the independently generated parent cache/compiler metadata
variation. Use retained warm/fresh artifacts; no new path investigation or
replay of the successful warm case is needed. Keep optional patched results
separate from regular Cargo raw cache reproducibility and original
cost/platform/ mirror/integration/adoption gates. Removing the backport requires
that its fix be present in the regular pinned Cargo, not merely merged upstream.

Implementation, reproduction and actual evidence are in the synchronized VM
note. Current R outcome event:
`20261013T044227Z-optional-cargo-qualification-implemented-runtime-sections-equal-next-metadata-gate.md`.

Actual runtime section proof:
tmp/nixos-patched-cargo-changed-diagnostic-20261013/elf/runtime-section-proof.json,
3974 bytes, SHA256
b2f55e89950806c7e12a56164126dcdf06c3b099cf2e94300f57d88462b025ed. Fresh-only
collection output:
/nix/store/x2l0qc36vm3fr19fmkwwxarjalqzwa0a-vm-test-run-rust-foundation-patched-cargo-fresh-artifact-collection.
Warm data is owned/hash-inventoried in retained-warm. Diagnostic collection
Source failures are recorded in the VM note; copied symlinks must not be
resolved against the host store. No new producer implementation fix selected for
the remaining compiler/cache metadata gate. No stage/commit/push, default change
or production patch.
