---
id: 20261003T045200Z-g4-qualification-claimed
at: 2026-10-03T04:52:00Z
actor: agent:rust-fabric-main
type: claim.started
subject: milestone:g4-execution-qualification-preparation
tags:
  - area:rust
  - authority:code-only
  - concern:execution-evidence
---

# Prepare explicit G4 qualification targets, without executing them

Human: "next phase" after fresh retained-worktree review. Continue the existing
code-only authority in the same worktree; this is not approval for compilation,
captures, fetching, daemon builds, root adoption, integration or publication.

Next useful workstream is preparation for actual G4 fallback qualification:
strict-subset archive inheritance, semantic baseline/member/legacy parity and
source/manifest/lock invalidation. Add isolated fixture/construction/acceptance
modules, not a generic executor/control plane or production unit ledger.

Assignments:

- MAIN: coordinator, scope/authority, README, durable notes/index/events,
  integration, bounded cached evaluation and closeout.
- `01a10014-d644-74c4-80f2-1cf4d9957bcd`: design (complete, no edits).
- `01a1001a-c5e5-74c4-80f2-1cff67c55c1d`: fixture implementation;
  `scripts/rust-g4-qualification/{fixture.py,test_fixture.py}`.
- `01a1001a-c5e8-74c4-80f2-1d004fb8dad6`: Nix construction/acceptance;
  `scripts/rust-g4-qualification/{default.nix,eval.nix,accept.nix}`.
- Independent reviewer: assign after implementation, before closeout.

Temporary coordination/evaluation under owned repository `tmp/`; append-only
plan events are durable authority. No production helper changes initially. A
concrete helper defect requires review rather than test-only producer overrides.

Dependency-free seven-member workspace, real source/build/proc-macro/dev
behavior, resolver 2, local lock v4, no default-member/profile/third-party
changes. Preserve prior role-capture fixture unchanged; its intentional
dev/default-member behavior is unsuitable for this subset-priming fixture.

Acceptance targets are explicit and unwired at root. Native execution remains
pending. Archive presence/inheritance and package behavior do not prove Cargo
freshness, external artifact reuse, exact units/features/effects or producer
fidelity. Keep producer `qualified = false`, decision `not_proven`. A later run
requires separately approved limits and external containment covering Nix daemon
builders, not client ulimit/timeout claims. No master/lock/default flips or
commits.
