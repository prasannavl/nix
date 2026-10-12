# Rust foundation: current handoff

Updated 2026-10-12. This file is synchronized byte-for-byte across the dedicated
Pvl qualification worktree and the Pvl and Abird main worktrees. The
qualification is **PAUSED by the human**. This note does not resume it.

## Three-tree layout

- **Qualification and result custody:**\
  `/home/pvl/src/nix/worktrees/rust-fabric-foundation-20261001` (**R**). This is
  the only destination for qualification work, current run sources, receipts,
  and raw qualification events. Keep the current M21 baseline and the unissued
  M22 source work here.
- **Pvl agent handoff only:** `/home/pvl/src/nix`.
- **Abird agent handoff only:** `/home/pvl/spaces/abird/src/z`.
- The Abird implementation candidate is
  `/home/pvl/spaces/abird/src/z/worktrees/rust-fabric-g4-port-20261003` (**A**).
  Pvl qualification does not establish Abird parity or acceptance.

The handoff and design contract are kept in each of the three destinations. The
main worktrees contain no copied qualification receipts, raw event stream, run
capsule, or history archive. Do not copy those back. When a result changes,
update this handoff and the R work README, then copy this exact file to both
main-worktree paths. The current R raw events remain the detailed authority for
qualifying work.

## Current truth

M21's original seven-stage manager chain passed, including the original manager
build and installed version `0.1.0`. Its complete ordinary build log recorded
zero external dependency compilation lines and two workspace compilation lines;
the two build steps took about 62 seconds and 0.15 seconds. The run used the
human-authorized 14 CPUs and 16 GiB. These are observed baseline results; the
run's CargoFresh field is `not_observed`, so they do not prove complete Cargo
freshness, the original 1 CPU/2 GiB cost case, or full qualification. The actual
M21 full receipt and its observed eight completed-native rows remain in R for
the pending case.

M22's forced warm manager case is authorized as the next runtime case but is
**unissued**. Its first Cargo step must retain the original forced
`97rg --rebuild`; its following packaging/version step retains the normal
`mpnp --rebuild=false` path. A new fresh proof must recheck current source,
custody, NAR/physical state, admission, resource limits and all original gates.
Do not replay old stages or reuse spent grants.

The Cargo/Crane archive timestamp investigation found that unchanged hooks can
produce different archive bytes when dependency timestamps change even when the
reconstructed files match. A candidate transport correction preserves canonical
epoch-1 metadata. The M21 baseline log is encouraging, but deterministic warm
archive equality and the production-path correction are **not yet qualified**.
Do not describe the timestamp issue as closed until the original warm acceptance
passes.

## Original design and non-negotiable acceptance

The goal is cache reuse through the existing Cargo/Crane member-package setup:
compile dependencies efficiently, reuse compatible artifacts, and limit
invalidation to the affected Rust member and its dependents. Do not add
unrelated libc or other-project investigations.

The original goals remain in force: G1 no IFD; G2 reduce repeated external
compilation; G3 source edits stay local to a member and dependents; G4 member
manifest edits stay local to that member's dependency closure and dependents
(root workspace dependencies and shared lock changes may be global); G5 a simple
package API; G6 maximal sound reuse; G7 composable, maintainable implementation;
G8 correctness and honest claims; G9 Pvl/Abird parity; G10 revision-owned
standalone package mirrors; G11 in-repository consumption of a mirror with
matching semantics and, where established, cache identity.

The selected architecture uses each member's declared source closure, one shared
full-lock vendor root, and Cargo artifact inheritance only over a verified
strict-subset dependency edge with a matching compile context. Existing Cargo,
rustc, Crane, features, flags, hooks, wrappers, constructors and package
behavior stay intact. No peer-derived feature union, pruned vendor or lock,
generated semantic stub, fabricated parent label, or permissive ownership
fallback may make a test pass. Source tests and metadata equality do not prove
runtime Cargo reuse.

Every original gate remains open until its own real result is recorded:

1. Actual manager build and installed version on the current original recipe.
2. Forced warm rebuild and real Cargo reuse evidence.
3. Peer, comment-only and member-manifest locality; compatible subset-parent
   reuse; no IFD.
4. Complete immutable mirror ownership and standalone/composed/in-repository
   parity.
5. Generic forwarding; Abird's 24-member cost measurement; supported native,
   WASM and Tauri lanes and explicit unsupported boundaries.
6. Useful payback from observed workflows, independent review, and separate
   human integration/default/adoption authority.

## Completed work, summarized

The pure member-closure/base design, shared lock/vendor policy, compile-context
checks, constructor plumbing and immutable mirror source/generator are present.
The canonical Cargo dependency-table handling fails closed on deprecated aliases
that could hide path edges. Existing Source/fixture suites, utility and CLI
acceptance completed within their recorded scopes. A 2026-10-12 M21 actual
manager/version chain passed as described above.

A cache transport candidate normalizes timestamp metadata to epoch 1. A bounded
warm attempt observed no external dependency compilations but Nix rejected
differing archive bytes; the cause of the differing bytes was reproduced with
unchanged Crane hooks and timestamp changes. The current M21 baseline and the
warm archive acceptance are distinct results. No historical receipt is required
to understand these outcomes; current receipts remain available only in R when
the pending case needs them.

Old manager attempts, Source-only checks, review receipts, copied proof packets
and raw historical streams are not deliverable project state. Their useful
outcomes and failures are summarized here and in the compact R work README.
Historical receipt bytes cannot be recreated as historical evidence. Fresh
qualification must generate fresh source bindings, controls, custody, proofs and
receipts from current inputs; it cannot claim to reproduce an old receipt.

## Next bounded unit after explicit resume

1. Read this handoff and the current indexes/plan in both main worktrees and R.
2. In R, completely read the original onboarding files named below. Then read
   the current R docs index, stable plan/work README, the human pause event, M21
   pass event and M22 scope event. Use those latest few raw events to confirm
   authority and state; the older work timeline is summarized above.
3. Inspect current R/A Git state and the saved M21 full receipt/metadata rows
   without printing raw receipt bodies or private runtime fields.
4. Fully review the existing M22 regression-v2 Source, its literal and delta.
   Regression-v1 was not run; v2 has not passed final review and has not run.
   Run its once-only RAM regression only after that review passes. A refusal
   closes the scope.
5. Finish the fresh M22 Source/control/factory preparation, regenerate bindings
   against actual current refs, review final Source and argv, then run the
   original M22 chain once under its original limits. The M22 factory is not
   published yet; a prior Source-preparation command is spent and must not be
   replayed.
6. Continue through the original gates above. Preserve the first forced rebuild
   and normal packaging/version semantics. Stop at the first refusal and charge
   the full reserved scope.

Qualification budgets and boundaries stay as recorded in R: 128 MiB total
public-read admission, original Source/read/program limits, BODY 30 seconds and
native 300 seconds with helper 20 seconds inside that aggregate. The 14 CPU / 16
GiB override used for M21 does not qualify the original 1 CPU / 2 GiB cost gate.
No retries, refunds, deadline extensions, private probes, compiler
instrumentation or default adoption follow from this handoff.

## Regenerating qualification inputs

Start from the current implementation and recipes; do not replay archived
commands or substitute a historical receipt.

- Implementation and current R/A source:
  `/home/pvl/src/nix/worktrees/rust-fabric-foundation-20261001` and
  `/home/pvl/spaces/abird/src/z/worktrees/rust-fabric-g4-port-20261003`.
- Current qualification and mirror code: `R/scripts/rust-fabric/qualification/`
  and `R/scripts/rust-fabric/mirror/`.
- Current constructor/public-input source:
  `R/.agents/runs/rust-foundation-accounted-constructor-v12-source-20261011/`.
  Its original finite admission is frozen; inspect it as implementation context,
  not as a grant to replay.
- M21 result required by M22:
  `R/.agents/runs/rust-foundation-manager21-20261012/` and its `-programs`
  sibling. Read only the exact current success receipt and its authenticated
  observed metadata through the bounded readers; preserve RAM-only handling and
  never print raw carrier values.
- M22 prior-controller Source candidates and unexecuted regression:
  `R/tmp/manager22-full-prior-source-20261012/`. Review v2; do not execute the
  historical command files. Fresh current bindings and a new once-only scope
  still need to be prepared.
- Current paused state and authority:
  `R/.agents/plans/work/2026-w40-rust-fabric-implementation/events/`. Read the
  pause event, then the current M21 pass and M22 scoped events before acting.
  Raw events remain authoritative over summaries.

The original M21 and M22 receipts, old Source bindings and finite-grant bytes
are evidence of past events, not regeneration inputs. They are retained in R
only where the live M22 chain depends on them. Regenerating qualification means
deriving fresh inputs from current Git refs, implementation, public recipes and
authorized current scope; then rerunning reviewed gates to create new evidence.
If required current Source or executor is missing, rebuild it from R's reviewed
implementation sources without restoring the deleted evidence collections.

## Documentation cleanup verification

The main worktrees retain the durable Cargo workspace note alongside this
handoff and the shared design contract. Removed historical proof collections are
absent, and the live M21 receipt and M22 Source candidates remain in R. The
shared handoff, contract and canonical plan are byte-identical across the three
destinations; R retains its separate active work capsule and staged changes.

Current documentation formatting and Markdownlint checks pass. The Pvl full
repository diff lint passes. Abird static lints pass; its full repository check
is blocked by the refreshed Nixpkgs marking the configured Kanidm 1.10.4 as
end-of-life. The separate Tailscale constructor-argument mismatch was corrected
in both its package and updater. No identity-service migration or insecure
package allowance was introduced. These repository checks do not qualify Rust
cache reuse or resume the paused qualification.

The unpublished main documentation series is consolidated into one final handoff
commit per repository. Abird's external input refresh remains a separate commit
with its Tailscale compatibility repair. Fresh M22 preparation must capture the
resulting current main refs; old event commit IDs remain historical
observations, not current bindings.

## New-agent starting prompt

```text
Continue the paused Rust foundation qualification. Use these absolute paths:
R=/home/pvl/src/nix/worktrees/rust-fabric-foundation-20261001
A=/home/pvl/spaces/abird/src/z/worktrees/rust-fabric-g4-port-20261003
Pvl main=/home/pvl/src/nix
Abird main=/home/pvl/spaces/abird/src/z

Qualification is paused. This prompt explicitly resumes it; do not launch any
unit before reading current state and reporting remaining gates. Read each
main's AGENTS.md and .agents/docs/README.md, .agents/plans/README.md and queue.
Then read this R handoff and COMPLETELY read:
R/.agents/docs/notes/tooling/rust-foundation-next-agent-prompt-2026-10.md
R/.agents/docs/notes/tooling/rust-foundation-handoff-2026-10-11.md

Read the current R design contract, plan/work README, latest human pause event,
M21 pass and M22 scope events. Preserve all original G1-G11 and acceptance
gates. M21 manager/version PASS; M22 forced warm is unissued. Next bounded unit
is full v2 Source/literal/delta review, then its once-only RAM regression only
if review passes. New finite current Source/custody/admission and current-ref
bindings remain required before the single original M22 chain.

Rebuild fresh qualification inputs from current implementation and recipes.
Never replay historical commands or closed grants. Keep actual receipts,
runtime evidence and work products in R only. Update this same handoff in R,
then copy identical bytes to both main worktrees and keep their indexes free of
proof/event/archive copies. No push, implementation merge, activation, default
adoption, or claim of full qualification is authorized by this prompt.
```
