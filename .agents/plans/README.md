# Plans Index

## Current Rust foundation route — 2026-10-13

Read the synchronized design, concise plan and main handoff first. Required
regular-Cargo reuse passed for Pvl and the six Abird native cases; both actual
candidate manager mirrors passed independent parity review. Abird's 24-member
constructor/context checks establish 20 native contexts and four unsupported
lanes, not 24-product or ARM execution. The isolated legacy comparison passed
with a 15.1% observed source-edit elapsed saving in the selected manager
workflow. Scoped final qualification is independently accepted and retained.
Next is separately authorized integration; adoption remains separate. All new
qualification VMs use 16 CPUs / 16 GiB by human instruction. Independent byte
determinism is optional; compiler metadata investigation is not the next
required unit. The historical cutoffs below do not select work.

## Historical optional qualification Cargo — 2026-10-13

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

At that historical cutoff, the next unit was parent cache/compiler metadata
variation. The latest human decision makes that investigation optional. Use
retained warm/fresh artifacts; no new path investigation or replay of the
successful warm case is needed. Keep optional patched results separate from
regular Cargo raw cache reproducibility and original cost/platform/
mirror/integration/adoption gates. Removing the backport requires that its fix
be present in the regular pinned Cargo, not merely merged upstream.

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

Evidence and exact upstream references are in the VM note. At that historical
cutoff, Cargo serialization was the next work and patched Cargo was forbidden.
The later human decision allows optional qualification-only patched Cargo; do
not silently normalize/delete binary fingerprints, waive the gate or label
final-binary identity as cache-archive identity. Build-path, tar timestamp and
tar-order experiments are finished for this proved pair. Full qualification
remains open. Current R raw root-cause event:
`20261013T030644Z-vm-cargo-dep-info-record-order-root-cause.md`.

Use this index as the canonical map for `.agents/plans/**`.

## Upstream

- `.agents/plans/upstream/nixos-lxc-runtime-system-links.md`: Draft upstream
  NixOS/nixpkgs plan for fixing LXC `/run/current-system` loss, distrobuilder
  generator store-path assumptions, special-filesystem ownership, and early
  udev/networkd boot failures.

## Rust foundation

- `2026-w40-rust-fabric-implementation.md`: active P2 coordination plan; M21
  passed, M22/M23 warm failed. Reader investigation closed; fresh M24 sandbox
  first-manager Source preparation is next. Original qualification gates open.
- `work/2026-w40-rust-fabric-implementation/README.md`: main-worktree agent
  route only. The R worktree contains the materialized active work, sources,
  receipts and raw events.
- `../docs/notes/tooling/rust-foundation-main-handoff-2026-10-12.md`:
  synchronized current truth, original goals, remaining gates and regeneration
  instructions.

The main worktrees contain no duplicate qualification evidence. The active
implementation remains in the explicit Pvl and Abird worktrees. This plan does
not close the independent host-manager/Nixbot integration or generic
multi-ecosystem work.

## Current Rust foundation acceptance — 2026-10-13

Independent-build byte determinism is now optional by explicit human decision.
Required work uses regular Cargo and validates actual Nix cache transport, Cargo
reuse and observable source invalidation. The current route is recorded in
`.agents/docs/plans/rust-foundation.md` and the VM note; all remaining G1–G11,
mirror/parity/platform/cost/review/adoption gates remain required.

Regular-Cargo required manager reuse now passed all six VM cases. Actual Nix
binary-cache restoration succeeded with builds disabled; warm cases compiled 2
workspace / 0 external crates and changed behavior appeared in both changed
builds. Independent compilation hashes differed as optional FAIL. Source/fixture
and native edit results, registered evidence and remaining closeout gates are
recorded in the current VM note and handoff. The next required bounded unit is
real immutable manager-mirror consumption; full foundation remains incomplete.
