# Abird post-`829d81ed` repeat port, 2026-09-16

## Authority and frozen boundaries

The user requested the same complete commit-by-commit audit and relevant shared
ports, directly in the primary main worktree. This explicitly overrides the
isolated-worktree rule for this session. Target started clean on master at
`da81db0097b86c4574ac0182fa7f24422ad06cc9` with one existing local commit
(`da81db00`, Pvl Kilo host policy) ahead of origin/master. Preserve that commit
and the unrelated active Nixbot runtime worktree. The initial audit left changes
uncommitted. The subsequent user request explicitly authorized committing all
repeat-port changes in main and pushing main; deployment remains outside scope.

Previous port source anchor: `829d81ed59b06d6d4500c92c5917facabcc92b26`. The
configured Abird remote is the local repository `/home/pvl/spaces/abird/src/z`;
its frozen master is `8fc966f85ead2804983062a01f330f584596631d` (nine commits
after anchor). Its freshly fetched upstream published master is
`95282f5a2436563b53564cafbaa16969fc9a1f65` (13 commits after anchor). These
diverge at `86b42091`: six published-only product documentation commits versus
two configured-remote-only updater/dependency commits. The union contains 15
distinct source commits, all classified below.

Source working files have unrelated staged and unstaged host-image/doc edits.
Only frozen Git objects were read for source implementations. Working edits,
source-only branches, live service/image updates and foreign publication
approvals are excluded. No secret content was read or imported.

## Logical units and outcome

1. New adopted updater unit (`0cf1f896`): anonymous registry Bearer challenges,
   HTTPS token realms, service/repeated scopes, token/access_token handling,
   authenticated tag retry, request-stage/timeout/endpoint attribution, all
   affected image contexts, and failed serial/parallel report jobs. Image check
   failures block all image pin writes; existing PostgreSQL same-major and nginx
   stable-track policy remains exact. Four code/test files are byte/mode exact
   to configured-remote source. Shared durable rules adapt into existing
   external-source-units design guide; Abird rollout/image inventories and
   authorization history are skipped.
2. Already adopted generic fabric coverage (`776d9cb7`): source has copied Pvl
   synthetic tests and retained its concrete topology separately. Pvl synthetic
   test is exact; do not import fabric-contract-abird.nix or its Abird topology
   check.
3. Already adopted Nixbot fixture isolation (`fa45f64b`): all three private
   config/state/runtime overrides already present. Keep the existing Pvl
   seven-host ordering test; production shell remains exact.
4. Already adopted VS Code extension input (`8fc966f8`): complete locked node
   matches revision 3e3e226511ba4b7758910df58336dfd2ca520dc5, hash, timestamps,
   original and follows. No root lock edit or graph replacement. All matching
   non-root lock nodes are already exact; Pvl-only graph retained.
5. Excluded published work: Abird reverse-port records, planning reconciliation
   and six future memory-product plan/policy/lifecycle/replay/backup/freshness
   commits. No shared memory implementation, backup module, package or service
   was added. A merge bringing old shared work from 829d81ed is already covered
   by the previous audit; there is no new executable merge resolution.

## Every published source commit

|  # | Commit     | Subject                                          | Status         | Included units                                                                                                          | Skipped units and reason                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| -: | ---------- | ------------------------------------------------ | -------------- | ----------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
|  1 | `ce607eed` | docs(plan): reconcile Phase 3 planning state     | skipped        | None                                                                                                                    | Abird Phase 3.7 governed memory plan, umbrella planning status, Peter delivery workflow and source event records. Documentation-only Abird product planning and participant workflow; no executable shared changes. Pvl follows its own user-authorized workflow.                                                                                                                                                                                                                                                                                                                                                                                |
|  2 | `deb38c62` | docs(plan): reconcile planning with master       | adopted        | Merged shared implementation from parent 829d81ed already present via prior Pvl ports                                   | Abird planning reconciliation, source workflow, publication events and product plan. Merge parents ce607eed and 829d81ed; compared merge to second parent: only Abird docs/plans/workflow changes. Compared to first parent includes previously-audited shared input/external/Pi/Kilo/updater units, already adopted at target base; no new executable resolution.                                                                                                                                                                                                                                                                               |
|  3 | `776d9cb7` | test(fabric): align shared contract coverage     | adopted        | lib/flake/tests/fabric-contract.nix byte and mode exact already; lib-flake-fabric-contract registration already present | lib/flake/tests/fabric-contract-abird.nix; abird-fabric-contract registration. Source adopts Pvl standalone synthetic coverage from f5e45bbc, correcting malformed negative IPv6 bases. Pvl generic test already exact; source-only test imports actual Abird stacks, Gondor/Platform/dev routes, product role placement and source inventory. Retain concrete Abird topology in source; no missing generic coverage.                                                                                                                                                                                                                            |
|  4 | `fa45f64b` | test(nixbot): isolate rollback authority fixture | cleanly ported | All three rollback fixture config/state/runtime temporary-directory overrides already present via 5a836363              | None. Rollback authority fixture isolation matches source. Full test-file difference is only the Pvl-specific seven-host control-plane ordering test retained in target; production nixbot.sh exact.                                                                                                                                                                                                                                                                                                                                                                                                                                             |
|  5 | `42257e77` | docs(parity): record five-commit repeat audit    | skipped        | None                                                                                                                    | Abird reverse-port audit/index/plan/archive/parity artifacts. Records five Pvl source commits through 6b42f622 and Abird test/package validation. Source bookkeeping is not implementation; current Pvl audit owns its own evidence.                                                                                                                                                                                                                                                                                                                                                                                                             |
|  6 | `ee9ce1e2` | style: format parity integration records         | skipped        | None                                                                                                                    | Abird reverse-port note, capsule README and integration-authorized event formatting. Markdown-only formatting of Abird-owned audit and coordination artifacts; no shared executable units.                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
|  7 | `86b42091` | docs(parity): close published repeat audit       | skipped        | None                                                                                                                    | Abird audit closeout, done-plan/capsule archive and publication events. Abird publication and worktree-removal record; no executable changes. Source sessions 776d9cb7/fa45f64b/42257e77/ee9ce1e2/86b42091 each explicitly classified.                                                                                                                                                                                                                                                                                                                                                                                                           |
|  8 | `0918cd99` | docs(plan): define memory requirement coverage   | skipped        | None                                                                                                                    | Private user/published workspace scopes, four-field profile, typed relationships, provenance-derived authority, retrieval/retention/timestamps and canonical JSON import/export; Abird point9 research, umbrella/platform/index/workstream records; foreign point9 master-publication approval in local-review playbook. This is unimplemented Abird controller/protocol/UI memory product planning. Pvl has no corresponding agentic-memory application vertical; referenced host-control seams are already documented locally. Foreign review/publication approvals are source history and do not authorize Pvl actions.                       |
|  9 | `aba7b11d` | docs(plan): define no-memory work policy         | skipped        | None                                                                                                                    | Account/task/goal/schedule no-memory policy, disablement epochs and provider/extractor fencing, context-influence inheritance and opt-out acceptance matrix; point4 note and source indices/events. Abird memory product policy remains gated and documentation-only. No shared host-agent, Nixbot, fabric, service library or package implementation changes. Do not import foreign user preferences or source-specific publication permissions.                                                                                                                                                                                                |
| 10 | `305c3e56` | docs(plan): define memory lifecycle              | skipped        | None                                                                                                                    | Logical-record versus revision lifecycle, private proposal publication, contradiction holds, expiry/deletion/supersession/rollback, generation/deadline/Read-Execute matrices and acceptance cases; point7 research and source coordination records. Abird controller Store/protocol memory lifecycle design and tests-to-be-written have no Pvl consumer. It adds no generic reusable library or repository language/design-pattern rule.                                                                                                                                                                                                       |
| 11 | `7568d1ef` | docs(plan): define deletion-safe memory replay   | skipped        | None                                                                                                                    | Permanent content-free mutation receipts and key reservations, canonical comparison material purge, erased-request retry/receipt recovery, controlled-copy/WAL cleanup, restore epoch fencing and UI pending-operation rules; point6 note and source events. Documentation describes future Abird application-memory deletion/replay semantics and SQLite Store operations, not the shared host-control publication/admission implementation. Existing Pvl infrastructure authority boundaries remain independent.                                                                                                                               |
| 12 | `64e32252` | docs(plan): define encrypted memory backups      | skipped        | None                                                                                                                    | Dedicated restic controller backup repository, operator-managed encryption/recovery custody, proposed30-day expiry and pruning cadence, protected scratch/verified readback/restore acknowledgement, retention/copy inventory and future recovery acceptance; point2 evidence and source coordination. Only a proposed Abird memory-controller backup contract. No restic package/service/timer, secret declaration, shared backup helper or reusable infrastructure module is implemented. General backup principles do not justify importing an absent product deployment plan or its foreign approvals.                                       |
| 13 | `95282f5a` | docs(plan): require fresh repository memory      | skipped        | None                                                                                                                    | Mandatory repository-memory source freshness against admitted snapshots, exact bounded file/range/hash dependency modes, binding/import/context lineage and proof purge, provider/broker budget/check boundaries, and standalone descriptive plan wording; point3 research plus source indices/events. Future Abird agentic-memory controller/cell/broker design is source-product owned. It references existing application evidence primitives but changes no code or Pvl shared module. Snapshot-bound product semantics must not become instructions for this port audit; Pvl host-control ownership guidance already remains authoritative. |

## Every configured-remote-only source commit

These two committed source units are exposed by Pvl abird/master but are not yet
in the frozen upstream published master. They are within the user-requested
Abird-remote audit; their provenance must remain explicit.

|  # | Commit     | Subject                                        | Status  | Included units                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | Skipped units and reason                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| -: | ---------- | ---------------------------------------------- | ------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 14 | `0cf1f896` | fix(update): handle registry auth and failures | adopted | Anonymous Registry V2 Bearer challenge negotiation: repeated/alternative headers, case-insensitive schemes/parameters, quoted commas, HTTPS token realms, retained query/service/scopes, token/access_token aliases, one authenticated retry; Docker endpoint alias with existing Quay/GitHub adapters preserved; HTTP diagnostics identify endpoint and opening/body phase, configured 20-second socket timeout and tag/token/authenticated operation; rendered URLs omit credentials/query/fragment; Image failures report every unique reference, detailed error and all deduplicated affected contexts; failed checks exit nonzero before image edit planning/writes; Serial/parallel report jobs and flake/image phases retain names and exit statuses in the final stderr failure footer; later success cannot clear earlier failure; All four changed production/test files copied from frozen 8fc Git objects with exact bytes and modes; localhost handling, Pvl working-directory evaluation, upgrade-track constraints and edit ownership/atomic safeguards preserved; Portable current registry/report failure contract adapted into existing .agents/docs/design-patterns/external-source-units.md. | Source .agents/docs/README.md index entry for its Abird incident note; current Pvl closeout is registered locally instead; Source .agents/docs/notes/tooling/update-registry-auth-2026-09.md Abird live inventory, proposed application version jumps, private overlay/worktree paths, old uncommitted/approval claims and historical live validation; retain only shared contract in current design guidance. Source local-only commit is relevant shared updater repair. Final scripts/tests are byte-exact; documentation is adapted to Pvl ownership without importing source historical authorization or approving upgrades. |
| 15 | `8fc966f8` | chore(deps): refresh vscode extensions         | adopted | nix-vscode-extensions locked revision 3e3e226511ba4b7758910df58336dfd2ca520dc5, timestamp and narHash already present; independently verified the complete vscode-ext node equals frozen source. Root verified all shared matching complete lock nodes already equal source.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     | No source root-lock replacement: Pvl root input graph/ownership remains repository-specific, and the complete relevant node already matches. Already adopted before this repeat port; this commit changes only six diff lines in the vscode-ext locked record. No flake.lock edit required or made by this session.                                                                                                                                                                                                                                                                                                               |

## Validation and review

- All 57 support tests pass: 41 image updater, 11 source discovery/orchestrator
  and five generic reporter tests. Tests use isolated mocks/fixtures; no live
  registry login or application update was performed.
- Existing packaged lib-podman-image-updater root check builds with import from
  derivation disabled against the live tracked port. This checks the 41 image
  tests in the actual Nix packaging boundary.
- Bash syntax, ShellCheck, packaged shfmt, packaged Ruff, Markdown formatting
  and whitespace checks pass. No new Nix files, graph changes or module
  consumers require intent-to-add state.
- Independent read-only review found no material issue in challenge/token
  handling, endpoint attribution, report status retention or write prevention.
  No missing shared dependencies or additional Pvl implementation adaptations.
- A plain explicit-base lint invocation would compare committed base..HEAD and
  omit these unstaged changes. Validation uses direct live-file checks and the
  actual packaged updater check; no misleading committed-range lint claim.

## Byte/mode parity

All 465 of 489 exact common lib/pkgs paths and every explained exception are
recorded in the [parity inventory](./abird-post-829-parity-2026-09.md). There
are 24 explained common content differences and 0 mode differences. This is one
more exact path than the prior 464/489 audit because source adopted the Pvl
synthetic fabric test. Incus, host-agent, host-manager implementation/tests,
service libraries and generic flake runtime helpers remain exact except the
already documented repository policy/test/doc boundaries.

No unexplained relevant shared gap remains in either frozen committed branch.
Future memory planning is source product intent and does not override Pvl
authorizations or repository ownership.

## Initial audit closeout

The final source fetch still resolves configured abird/master to 8fc966f8 and
published master to 95282f5a: no additional committed units remain to audit. All
15 source commits are classified (10 skipped, four adopted, one cleanly ported);
one new shared updater unit was needed. All 20 common scripts are byte/mode
exact to configured source. The existing local main commit da81db00 is
preserved; at initial audit closeout, all repeat-port changes were unstaged in
main and the index was unchanged. No task worktree was created or removed. The
unrelated Nixbot runtime worktree present at the start is no longer registered
at closeout; this task did not modify or remove it. Reports and the index are
formatted and task-specific scratch files were cleaned up. No commit, push or
deployment was performed during the initial audit.

## Authorized main publication

The user subsequently requested `$git commit all into main and push`. Main is
the primary worktree on master, tracking origin/master. Publication preserves
the existing signed local commit da81db00 and adds logical commits for the
shared updater and its audit records. The updater commit is 4c800bb4
(`fix(update): port registry auth and failures`); this record and the index form
the following audit commit. No side worktree, cherry-pick or deployment is
needed.

The configured .githooks/pre-push hook requires a clean worktree and runs the
no-IFD repository lint over the full outgoing range on all supported systems.
Publication uses that hook without a duplicate preliminary lint cycle. Final
verification compares local HEAD, origin/master and the live origin master ref,
checks divergence and confirms a clean worktree.
