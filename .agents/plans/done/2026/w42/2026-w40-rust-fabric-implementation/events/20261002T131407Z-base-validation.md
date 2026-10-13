---
id: 20261002T131407Z-base-validation
at: 2026-10-02T13:14:07Z
actor: agent:rust-fabric-main
type: milestone.validated
subject: milestone:explicit-unchained-base-admission
tags:
  - area:rust
  - kind:validation
  - skill:nix
  - collaboration:parallel
---

# Explicit unchained base seam validated

- Implementation lane delivered `mkClosureBase` and optional derivation-valued
  `base`, reconstructing the producer under actual consumer context. Labels and
  source-selection recipes are not opaque compatibility certificates.
- Independent reviewer `agent:01a0fcb2-4490-74c4-80f2-1bfeeba65d80` found a P2
  integration-test defect: shallow library overrides retained the old fixed
  point under root `rustToolchainFor`. MAIN repaired them with `pkgs.extend`.
  Scoped re-review and independent overlaid checks report no remaining P1/P2.
- Coordinator executed 57 pure base assertions and 114 closure assertions; 46
  real-Crane assertions pass in bare and normal root-overlay contexts on both
  Linux architectures. Reviewer independently reran overlaid contexts.
- Implementer reports 86 unchanged default paths; reviewer independently sampled
  60 actual HEAD-versus-current paths without differences. These are evaluated
  derivations, not compiled/reused artifacts.
- Initial support remains strict: native/evaluator-visible workspace, exact
  declared closure, full regular lock, default flags/profile, no caller native/
  environment/hooks/build customization. Opaque/mismatched bases reject; null
  defaults remain unchanged. No parents, composition modes or default flips.
- Generic/pinned checks are registered at their proper shared/identity owners.
  Code/tests/docs remain unstaged and uncommitted in the retained worktree.
- Next milestones: broaden reviewed compiler-vs-packaging projection, genuine
  subset chaining and opt-in composition, then locality/reuse/cost and mirror
  gates. Exact producer/ledger/unit execution remain unqualified and
  unimplemented.
- No additional builds, capture, providers, GitHub pushes, root/host evaluation
  or master publication occurred. Additional runtime qualification needs a
  separately bounded approval. Keep this plan active; do not archive it.
