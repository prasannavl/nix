---
id: 20261003T120000Z-forward-only-direction-and-legacy-scope
at: 2026-10-03T12:00:00Z
actor: agent:rust-fabric-main
type: decision.recorded
subject: milestone:g4-forward-only-invalidation
tags:
  - area:rust
  - direction:forward-only
  - blocker:legacy-retirement-scope
---

Human corrects next-phase goal: "what member to legacy? we don't aim to
returning back after this design is successful". MAIN removes
member->legacy->member rollback sequence from next-phase scope. Member mode is
the forward design, not a stepping stone back to legacy. This supersedes
rollback wording in `20261003T115100Z-g4-invalidation-preparation-claimed.md`.

Human adds: "so if that was the goal, then we should remove all legacy related
ones to keep it clean". MAIN asks whether cleanup means qualification harness
only or also production `baseMode="legacy"` / `useWorkspaceDeps=false` support,
which changes existing package contracts. Awaiting clarification before retiring
those interfaces or wider legacy harness entries. Preserve historical evidence
rather than rewriting past observations. No defaults/adoption/publication
authority inferred from this question.

Implementor `01a10199-d5e5-74c4-80f2-1db5a6cb2fb2` completed only new
`invalidation.nix` and `invalidation-eval.nix`: forward-only explicit target
`memberInvalidation` with four member variants, no rollback/legacy native route;
29 constructor controls forced before target construction. Owner reports 18
cached offline/no-IFD assertions, Alejandra/Bash syntax/ShellCheck pass, own
staging cleaned. Existing files unchanged, 190 staged paths preserved, no native
execution. MAIN validation/independent review/documentation closeout still
pending; owner report is not native invalidation/freshness/reuse proof.
