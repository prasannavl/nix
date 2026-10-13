---
id: 2026-w40-rust-fabric-implementation
state: active
updated_at: 2026-10-13
---

# Rust foundation: main-worktree agent route

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

## Confirmed VM determinism cause — 2026-10-13

A fresh human-selected diagnostic retained the baseline and Nix .check outputs
of the original manager member-layer recipe. Only target.tar.zst differed. Both
tar streams have 39 entries with identical order and headers. Every archived
payload matches except Cargo's binary dep-info for the agent and manager
libraries. Those two files contain identical raw dependency-record multisets (27
agent / 58 manager), identical format/version/count/environment bytes, and
differing record order only. Executables, rlibs, rmeta, text .d files and other
fingerprint payloads match. Warm compilation remains 2 workspace / 0 external.
Baseline build/package/version passed.

The pinned Cargo 1.95.0 (f2d3ce0bd) writer collects paths in a HashMap, iterates
it without sorting, then serializes the resulting vector. HashMap random seeds
vary that iteration order across Cargo processes. Crane archives the binary
dep-info unchanged, so Nix correctly rejects different cache-output bytes. This
establishes the cause for the current sandboxed pair, not every historical
unsandboxed mismatch. No compiler/toolchain/fingerprint or producer changes were
made; this diagnostic collection is not successful warm qualification.

Evidence and exact upstream references are in the VM note. Next work must
address Cargo dep-info serialization through a compatible solution. The current
contract forbids patched Cargo or fingerprint reimplementation: do not silently
normalize/delete binary fingerprints, waive the gate or label final-binary
identity as cache-archive identity. Build-path, tar timestamp and tar-order
experiments are finished for this proved pair. Full qualification remains open.
Current R raw root-cause event:
`20261013T030644Z-vm-cargo-dep-info-record-order-root-cause.md`.

Implementation and raw events live only in R:
`/home/pvl/src/nix/worktrees/rust-fabric-foundation-20261001`. This main
worktree carries informational routing only. Read the synchronized handoff and
VM note before selecting work. Human validation preapproval persists; production
integration/adoption remain separate.

## NixOS VM implementation and current result

The human-authorized NixOS test framework is implemented in R under
`scripts/rust-fabric/qualification/`. Two disposable guests have independent
writable seeded store images, no host-store mount, no remote builders or
substituters, no guest network fetching and no IFD. Nix uses sandbox=true,
sandbox-build-dir=/build and sandbox-fallback=false. Original manager
Cargo/Crane recipes, compiler flags, full lock/vendor and compatibility guards
remain unchanged.

The final smoke passed baseline, forced unchanged warm, changed warm and
independent changed fresh, including exact guest derivation identities,
seed-output absence, installed behavior and NAR equality. The actual manager V4
baseline build/version passed; its forced unchanged warm rebuild failed Nix
output equality. Ordinary warm logs contain exactly two workspace compilations
(agent and manager) and zero external compilations, both under
/build/cargo-workspace-source. Fixed sandbox paths alone are insufficient for
artifact determinism in this case. The subsequent retained pair proves Cargo
binary dep-info record ordering as the current cause (see confirmed result).
Changed manager cases stopped at that first refusal and were not run.

Next work is a bounded artifact-determinism implementation fix preserving the
compatibility contract, followed by this existing matrix. Do not replay a spent
case, expand the VM harness, or reopen archive-reader work. CargoFresh remains
not_observed and full qualification, original cost, mirror, Abird/platform and
integration/adoption acceptance remain open. The 7-core/8-GiB guest environment
is separate from the original cost gate. M24 remains closed.

Reproduction, seed selection and retained evidence are documented in
`.agents/docs/notes/tooling/rust-foundation-nixos-vm-2026-10.md`. Current R
validation event:
`20261013T023437Z-nixos-vm-matrix-implemented-and-manager-warm-refused.md`.
