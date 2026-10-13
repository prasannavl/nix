---
id: 20261005T043600Z-existing-toolchain-correction
type: human-direction-and-architecture-correction
plan: 2026-w40-rust-fabric-implementation
actor: agent:rust-fabric-main
state: custom-cargo-route-stopped-existing-toolchain-required
coordinator: agent:rust-fabric-main
tags:
  - area:rust
  - work:exact-producer
  - constraint:existing-toolchain
---

# Human rejects the custom-Cargo route

Human: "that's entirely not the plan.. we shouldn't be replacing the toolchain..
we should be using the existing toolchain". This overrides prior agent-proposed
internal Cargo instrumentation/construction roadmaps, including next-step Cargo
vendor-payload extraction, normalized patch intake for reconstructed Cargo and
paired patched-reference/instrumented binaries. They are **not** pending
resource or phase approval: they are not the intended implementation. Leaving
installed defaults untouched but substituting custom Cargo for fabric capture
still violates this constraint. Standing autonomy and "next" did not authorize
that substitution.

Agent acknowledges architectural drift: source/API research was incorrectly
promoted into a required custom toolchain implementation without reconciling the
original existing-toolchain constraint. Correct route must use existing selected
Cargo/rustc/wrappers, preserve flags/default semantics and native/G4 fallback.
Capture capability must be established from supported existing
interfaces/external observations, not claimed from private hooks. Exact
graph/origin/invocation/effect requirements stay intact; unsupported/unproven
observations fail closed or use native/G4 fallback rather than guessing or
weakening the ledger contract.

No rebuild/patch application/installation/default toolchain replacement occurred
in the recent source phases. All Cargo-internal candidates remain uncompiled/
unapplied/unqualified. Preserve archive/projections/raw tests/reviews/receipts
as historical research/local custody; neither delete history nor treat scoped
code review as architectural approval. No existing staged ownership inferred.

Active plan/work view and docs index/most-specific correction note updated;
source-contract/source-inspection/handoff entry points mark reconstruction
claims superseded. First next source task is existing-toolchain capability/gap
assessment and corrected scope, not Cargo reconstruction. No new
native/fetch/archive/patch/ Git/publication grant; old allocations remain
closed. Product builds using the existing toolchain are a different operation
and retain concrete safety/resource and qualification gates. P2 queue/mission
remains active.
