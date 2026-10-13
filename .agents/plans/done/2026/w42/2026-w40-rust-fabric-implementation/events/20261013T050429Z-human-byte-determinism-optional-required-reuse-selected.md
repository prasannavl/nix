---
type: decision
plan: 2026-w40-rust-fabric-implementation
actor: human
recorded_by: agent:rust-foundation-main
recorded_at: 2026-10-13T05:04:29Z
---

# Independent-build byte determinism is optional

Human explicitly authorized keeping byte determinism optional because project
and dependency reproducibility is outside the foundation's guarantee. Required
acceptance is Nix cache reuse, Nix/Cargo DAG reuse and the original primary
goals. Releases use fresh Nix builds. No remaining locality, mirror, parity,
platform/cost, review or integration/adoption requirement was waived.

Select regular Cargo validation with exact original recipe identities. Required
Nix binary-cache transport must preserve the actual exported output's NAR;
independent recompilation equality becomes an optional diagnostic only. Force
ordinary warm recompilation by removing only tested outputs in disposable guest
stores, retaining genuine dependency bases. Validate existing-cache hits, local
binary-cache substitution with builders disabled, compilation frontiers and a
source edit with observable behavior. Strict determinism remains explicit
opt-in; no output normalization, compiler flag change or production overlay.

This is an acceptance/work-order decision, not a validation PASS. Metadata
root-cause investigation is no longer next required work. Historical failures
and spent units retain their original status. No stage/commit/push or adoption
was authorized.
