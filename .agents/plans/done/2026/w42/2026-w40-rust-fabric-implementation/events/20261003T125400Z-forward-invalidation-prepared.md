---
id: 20261003T125400Z-forward-invalidation-prepared
at: 2026-10-03T12:54:00Z
actor: agent:rust-fabric-main
type: validation.completed
subject: milestone:g4-forward-invalidation-and-selector-cleanup
tags:
  - area:rust
  - authority:code-only
  - direction:forward-only
  - compatibility:isolated-builds-kept
  - gate:native-edits-pending
---

# Forward preparation and legacy-selector cleanup complete

Human clarified only legacy mode/routes retire; all isolated support remains.
MAIN coordinates; core implementor `01a101c2-0e3c-74c4-80f2-1dc04fa1376a`,
qualification implementor `01a101c2-9395-74c4-80f2-1dc3bb37b325`, independent
read-only reviewer `01a101d0-8d57-74c4-80f2-1dc8f215fc97` completed lanes.
Initial forward module author `01a10199-d5e5-74c4-80f2-1db5a6cb2fb2` also
complete. Core lane resumed after unexplained UI abort; no partial lane remains.

## Code and contracts

- `member-bases.nix`: allow only null/member/union, remove legacy alias/branch;
  retired selector fails before planning and explicit base/null/false escapes.
  No replacement name/hidden legacy selector.
- `useWorkspaceDeps=false`, package-specific dependency producers, standalone/
  no-Crane paths, default policy, explicit admitted-base precedence all
  retained. Helper edits only explanatory comments/error text; generated
  commands unchanged.
- Active G4 harness removes legacy consumer/test/build/parity routes. Eleven
  baseline/member/test/base targets remain; historical
  thirteen-target/three-route real smoke evidence/logs/append-only events kept
  intact.
- New isolated `invalidation.nix` / `invalidation-eval.nix`: exactly four member
  variants; one explicit `acceptanceTargets.memberInvalidation`. Actual
  constructor guards forced before target construction;
  bad/missing/swapped/identical source variants reject. Expected files carry
  STORE contexts. Runtime four actual binaries match their own expected bytes,
  Rust edit diverges, neutral manifest/ lock edits preserve output; cmp status2
  fails, not successful inequality. Metadata reports discard context without
  adding peer/check output dependencies. No rollback sequence, activation, extra
  native routes or default/adoption switch.

## MAIN validation

Cached offline specific modules, IFD disabled, no `path:` flake refs:

| Context     | Fixture | Invalidation | Forced controls | Base | Composition | Native-context | Scope |
| ----------- | ------: | -----------: | --------------: | ---: | ----------: | -------------: | ----: |
| x86 bare    |      27 |           18 |              30 |  105 |          41 |             73 |   134 |
| x86 overlay |      27 |           18 |              30 |  105 |          41 |             73 |   134 |
| ARM bare    |      27 |           18 |              30 |  105 |          41 |             73 |   134 |
| ARM overlay |      27 |           18 |              30 |  105 |          41 |             73 |   134 |

Fifty pure composition policy assertions and 28 Python fixture tests pass. Owner
emitted archive/semantic/invalidation scripts pass Bash syntax/ShellCheck (only
Nix-supplied `$out` SC2154 excluded). Alejandra, targeted Deno Markdown and
staged/ unstaged whitespace checks pass. No Cargo/native/container/fetch
operations. ARM evidence is evaluation, not execution.

Seven current same-constructor identity Boolean comparisons pass before JSON:
default/null/union/member, isolated, absent isolated member layer, explicit-base
with workspace dependencies disabled. Full drv/output/store triples are
compared; no pre-edit historical snapshot exists, so NOT before/after identity
evidence. Report-only raw `outPath`-coerced rows are not promoted to three-field
certificates.

Independent reviewer found no scoped P1/P2 in selector/isolation, source guards,
STORE contexts, runtime comparison and report-only dependency boundaries.
Reviewer read sources, did not independently rerun MAIN matrix or realize
targets. Producer stays `qualified=false / not_proven`; no exact Cargo
freshness/reuse/unit DAG proof.

## Durable closeout and next gate

Static work-capsule `evidence/20261003T123300Z-forward-invalidation/` retains
four-context matrix, 76 original variant file hashes and current isolation
controls. These are construction observations only. Indexed G4/subset/mirror
notes, docs index, canonical plan, work view and harness README updated for
clarified direction. Successful owned `tmp/g4-invalidation-preparation` and
`tmp/g4-remove-legacy-core` staging cleaned; unrelated helper
consolidation/current mirror log retained.

HEAD/Pvl master `5ae0baf0`, Abird master `1f4057ee`; 190 older staged paths
preserved. No stage/commit/push/integration/publication, deployment or
root/Abird adoption. Active plan remains queued, not archived.

Edited-variant native acceptance has NOT run. Next run requires separately
approved scope/aggregate budget and externally contained ordinary-worker
backend, complete pruned offline readiness. Previous writer cache was private
and cleaned; do not assume host availability or implicitly fetch/rebuild
prerequisites. Compiler/ profile/flags/defaults unchanged; no budget carried
over from successful smoke.
