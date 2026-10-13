---
id: 20261004T135816Z-cargo-source-acquisition-approved
type: approval-and-workstream-claim
plan: 2026-w40-rust-fabric-implementation
actor: agent:rust-fabric-main
recorded_at: 2026-10-04T13:58:16Z
state: source-acquisition-claimed
coordinator: agent:rust-fabric-main
tags:
  - area:rust
  - work:producer-source
  - scope:acquisition-only
---

# Pinned source acquisition and Cargo-only inspection

## Human direction and exact authority

MAIN asked whether to approve acquisition-only of the pinned Rust 1.95.0 release
archive, hash verification and guarded Cargo-only inspection under the proposed
300s/512MiB compressed/128MiB selected/2GiB memory ceilings. The human replied
"next phase". Proceed with that scoped proposal, not a broader native grant.

Allowed URL: `https://static.rust-lang.org/dist/rustc-1.95.0-src.tar.gz`.
Expected flat SHA-256: `sha256-6puCqD5GlnU3w1ac6db6FoEcBDqW5lE3bDSecCQcpRU=`.
One transfer/attempt only, no automatic retry or broader source/provider intake.
Worker download, hash and guarded archive inspection/extraction share a 300s
wall allocation. All downloader/decompressor children must be covered by its
memory/deadline containment; no daemon builders are involved.

Selected source is only the canonical release root's `src/tools/cargo` subtree:
regular files/directories, bounded counts/bytes, no duplicate normalized
selected destinations, unsafe links/special entries/traversal/secret paths or
whole-Rust extraction. Inspected entry ceiling100000, selected ceiling20000. The
bundled vendor remains archived. No downloaded code may execute.

Explicitly excluded: compiler/Cargo/Nix realization, native qualification, patch
acquisition/application, instrumentation execution, backend/cache recreation,
Git writes/integration/publication, default adoption and deployment. All
previous native grants remain closed. A verified source archive is not a
qualified producer, tested build recipe or installed-binary patch attestation.

## Ownership and preparation

- MAIN owns the sole real acquisition, exact source binding, resource
  accounting, source inspection, documentation and evidence closeout.
- Helper implementor: `01a10736-e76a-7761-baac-1140d8fac15e`; owns new
  acquisition helper and synthetic safety tests only. No real network or source
  execution delegated.
- Independent focused helper review required before the real attempt.

Owned helper staging: `.agents/runs/rust-cargo-source-20261004T135816Z/`. Fresh
source destination: `tmp/rust-cargo-source-20261004T135816Z/`. Evidence:
`evidence/20261004T135816Z-cargo-source-acquisition/`.

Entry snapshot protects935existing paths:926staged entries and9prior owned
untracked documentation/evidence records. Index hash remains
`71180b2890a451ffa8b2feeb9032ff7283133a61b009c3ab14829b7e9562c423`. Unknown
staged ownership, both retained worktrees, primary-tree drift and unrelated
scratch remain protected. No index mutation is permitted.

## Stop conditions and next boundary

Reserve/account the one worker allocation before launch and bind reviewed helper
bytes. Missing tools, hash mismatch, unsafe archive, excess bytes/entries,
timeout or ambiguous process completion stops the phase without a retry. Retain
useful owned failure diagnostics rather than silently widening/resetting scope.
On success, inspect verified Cargo source to identify actual graph, scheduler,
compiler/build-script invocation and freshness seams; keep remaining
effect/provenance/patch/build gates explicit. No exact ledger or unit executor
is admitted by this phase.
