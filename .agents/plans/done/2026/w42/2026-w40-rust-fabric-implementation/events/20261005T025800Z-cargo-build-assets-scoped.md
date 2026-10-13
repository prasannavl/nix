---
id: 20261005T025800Z-cargo-build-assets-scoped
type: decision-and-execution-scope
plan: 2026-w40-rust-fabric-implementation
actor: agent:rust-fabric-main
state: offline-build-assets-and-vendor-metadata-preparation
coordinator: agent:rust-fabric-main
agent_roles:
  - agent:01a109ff-83ea-7761-baac-11d61fcd135d:inspector-preparation
  - agent:01a109ff-e66f-7761-baac-11d90efa0860:metadata-verifier
tags:
  - area:rust
  - work:exact-producer
  - scope:bounded-offline-archive
---

# Next build-input phase under standing autonomy

Human: "next". MAIN declares one fresh offline source allocation, not a retry or
reopening of old grants:300s external wall deadline,2GiB AS,one CPU,4GiB
decoded, 64KiB archive metadata,500000physical
headers,20000selected/materialized entries, 128MiB selected file bytes,512MiB
compressed input/member caps. MAIN owns sole real archive invocation after
independent helper/supervisor review and synthetic controls. Full allocation
charged/closed even on early success/failure; no second attempt or relaxed guard
silently inherits it. No network/transfer/build/patch/
Cargo/compiler/Nix/Git/default/installation/publication authority.

Input retained read-only0400 single-link authenticated Rust1.95 archive at plan
`source-inputs/rustc-1.95.0/archive.tar.gz`, flat SHA-256
`ea9b82a83e46967537c3569ce9d6fa16811c043a96e651376c349e70241ca515`. Require full
hash before parser and after inspection, unchanged held-FD metadata, complete
gzip/tar/report/inventory admission and reaped worker/external group absence. No
downloaded-code execution; unselected bytes still streamed/decoded.

Declared path-only `rust-cargo-build-assets-and-vendor-metadata-v1` preserves
Rust root-relative layout. Select prior Cargo implementation/manifests; original
bench members' manifests/Rust sources; real man/generated-text assets,
git-commit-info, Windows manifest and compile-time-included timings.js; root
Rust config/licenses/ COPYRIGHT when present. Cargo license
aliases/tests/fixtures/docs/CI remain explicitly excluded except named build
assets. Select all vendor root package Cargo.toml and .cargo-checksum.json
descriptors only, **not vendor source payload**. Selected path/sensitive
ancestor/link/special/mode/duplicate/conflict protections remain strict. Global
structural/GNU/PAX/CRC/deadline guards unchanged; no blind extraction or
secret-directory policy relaxation.

Cargo.lock v4 source contains533packages:507registry/26local, no Git; workspace
members crates/_,credential/_,benches/benchsuite,benches/capture. Later pure
verifier must compare descriptor package/name/version/checksum/file-map facts
against the complete lock and source inventory, not infer identity from
directory spelling, resolve features, rewrite manifests/lock or treat metadata
as payload verification. Always
vendorPayloadVerified=false/nativeBuildReady=false/Q=false; missing/
ambiguous/mismatched/unsupported inputs remain explicit.
Twenty-four-member/native/ effects/executor qualification is not established by
metadata.

New owned helper/test/verifier stages and empty tmp target are separate from all
frozen prior evidence/source. Baseline1855protected entries,index926staged and
archive metadata only under
`evidence/20261005T025800Z-cargo-build-assets/before.json`. Unknown staging
ownership preserved. Independent reviewer assignment follows when prepared code
stabilizes; MAIN promotion/custody and durable docs closeout required.
