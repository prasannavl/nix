---
id: 2026-w40-rust-fabric-implementation
state: paused
created: 2026-10-02
---

# Rust foundation

## Objective

Finish qualification of the existing Cargo/Crane cache design: member-local
source closures, shared full-lock dependency artifacts, genuine strict-subset
inheritance, preserved package contexts, and immutable standalone/composed
mirrors. Establish correctness and useful measured speed before adoption.

## Current state

Human-paused on 2026-10-12. M21's original seven-stage manager build and
installed version 0.1.0 passed. The complete ordinary log recorded zero external
and two workspace compilation lines. The 14 CPU / 16 GiB run does not establish
CargoFresh or the original 1 CPU / 2 GiB cost gate. M22's forced warm case is
scoped and unissued. The candidate epoch-1 timestamp transport fix and
deterministic warm archive equality still need the original warm acceptance.

Implementation work, current qualification sources, raw decision events and
actual evidence live only in
`/home/pvl/src/nix/worktrees/rust-fabric-foundation-20261001`. The two main
worktrees contain handoff information only. Read their indexes first, then use
the current handoff as the sole compact context route.

## Acceptance

All original goals G1–G11 and gates remain active: actual manager build/version;
forced warm Cargo reuse; peer/comment/member-manifest locality; strict-subset
inheritance; no IFD; complete immutable mirror ownership; standalone/composed/
in-repository parity; generic forwarding; Abird 24-member cost and platform
coverage; useful payback; independent review; separate human integration and
adoption authority.

## Work order

After explicit resume, fully review the existing M22 regression v2 Source,
literal and delta. Run its once-only RAM regression only after that review
passes. Then finish fresh M22 Source, controls, current-ref capture, admission,
custody and NAR checks; independently review final Source and argv; execute the
original forced-rebuild and packaging/version chain once. Continue through the
original matrix without weakening gates or replaying spent units.

## Context

- Handoff/results/source regeneration:
  `.agents/docs/notes/tooling/rust-foundation-main-handoff-2026-10-12.md`.
- Architecture and rejected alternatives:
  `.agents/docs/design-patterns/rust-foundation.md`.
- R's active implementation plan/work README and raw events contain detailed
  coordination state. Main worktrees do not carry the qualification capsule.
