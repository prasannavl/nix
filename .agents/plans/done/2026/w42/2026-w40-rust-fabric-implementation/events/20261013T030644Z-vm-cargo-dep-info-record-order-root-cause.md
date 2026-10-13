---
type: validation
plan: 2026-w40-rust-fabric-implementation
coordinator: agent:rust-foundation-main
author: agent:rust-foundation-main
timestamp: 2026-10-13T03:06:44.323593+00:00
---

# Original sandboxed manager mismatch traced to Cargo record ordering

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

Fresh actual collection output:
/nix/store/fi62hnfwb06bhvp8spq7wsbf4xqnspar-vm-test-run-rust-foundation-artifact-determinism-diagnostic.
Only the archived two binary dep-info payloads differ; unchanged tar headers,
entry order and complete raw-record multiset/prefix/suffix equality are proven.
Exact current Cargo commit f2d3ce0bd upstream implementation provides the
unsorted HashMap -> vector -> serialize causal path. Diagnosis-only source, full
logs, artifacts and reproduction are retained in owned tmp while needed for the
follow-on implementation choice. Qualification remains false; no production
defaults/recipes or compiler/fingerprints altered.

Evidence pins:

- tmp/nixos-vm-determinism-20261013/source-inventory.json: 474 bytes, SHA256
  159e87ef1fdf167ae8a7e09adf9e1d712150e26a2a1203162324b83cc553c3c6.
- tmp/nixos-vm-determinism-20261013/dep-info-order-proof.json: 1428 bytes,
  SHA256 f43b7b8fb0ba10822308445489aeb6149778f99319beef187d1ab205e8b29f8e.
- tmp/nixos-vm-determinism-20261013/build.log: 306493 bytes, SHA256
  cdbc20d0d73c0bbcd0c2c9c70b2cf8af3d78f3fa151abb593df708bdfcb7cbac.
