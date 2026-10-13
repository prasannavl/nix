---
id: 20261002T135305Z-subset-composition-validated
at: 2026-10-02T13:53:05Z
actor: agent:rust-fabric-main
type: milestone.validated
subject: milestone:subset-chaining-and-opt-in-composition
tags:
  - area:rust
  - kind:validation
  - skill:nix
  - collaboration:parallel
---

# Guarded chaining and opt-in composition validated

- Chaining implementer delivered recursive version-2 construction/admission,
  preserving unchained v1 and null paths. Its session was interrupted and
  resumed; completed handoff has no unresolved code/test failure or temporary
  state.
- Coordinator delivered the 91-line composition factory and separate tests. No
  root-wide injection or author inventory. Omitted/union mode retains old
  policy; explicit bases/null and explicit dependency disabling bypass automatic
  selection. Actual helper reconstruction establishes context equivalence, not
  recursive package-set equality. Unsupported requested member contexts reject.
- Chaining reviewer `agent:01a0fcda-5400-74c4-80f2-1c0ec6751e06` finds no P1/P2
  constructor/admission issue and independently runs all 103 pure/104 real
  tests.
- Composition reviewer `agent:01a0fcd5-0b07-74c4-80f2-1c0ddb77db8b` finds no
  P1/P2 wiring issue. Suggested escape/context regressions were added by
  coordinator.
- Coordinator executes 103 pure base, 41 pure composition and 114 closure
  checks; 104 real-base plus 32 real-composition assertions pass in each
  bare/overlaid x86/ARM Linux context. Cached offline no-IFD only, not
  compilation.
- Seven-member source-copy diagnostic: adding a leaf manifest feature changes
  only leaf/branch/middle/application base paths. Peer and cycle bases stay
  stable; leaf Rust-content edit changes zero base paths. This is narrow
  evaluated locality, not resolved Cargo units, runtime reuse/archive
  inheritance or cost acceptance.
- New note `rust-subset-composition-2026-10.md` records APIs, limits and
  evidence; indexes and prior milestone notes are reconciled. Successful staging
  is cleaned.
- Initial native/default-only contexts remain. No broad hook/profile/native
  projection, master publication, defaults, compilation/capture/fetch or
  exact-unit qualification occurred. Further runtime/cost and adoption/mirror
  gates remain.
- All parallel claims are complete. Keep the plan active for remaining
  milestones; source changes remain unstaged and uncommitted in the retained
  worktree.
