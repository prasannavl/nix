# Abird Post-156 Port, 2026-08

## Scope

- Pvl baseline: `77d123d51faa56b0abdd63b5cc13ff77b4832bd8` on the primary
  `master` worktree.
- Previous shared Abird tip: `15609f9e1411b35fe922365deff086b907eb716a`.
- Frozen and fetched Abird tip: `8ed010e74e12ddfbf482e4e789f39117b761c092`.
- Final Pvl port tip: `8760e8553ca0ce0caca24160db1a2662f9c1fe15`.
- Audit window: `15609f9e..8ed010e7`, 65 commits in source order.
- Landing surface: the primary `/home/pvl/src/nix` worktree on `master`.

Three parallel read-only reviews classified the first 64 commits before
integration. Reusable implementation was then applied from the frozen final
source blobs so intermediate commits could not leave cumulative byte drift. A
post-integration review produced commit 65 as a shared Abird safety repair,
which Pvl had already adopted byte-for-byte. Abird product, topology,
projection, plan, and live-operation state stayed excluded.

## Per-commit ledger

|  # | Commit     | Subject                                                        | Final disposition                                                                                                                                                                                                                                             |
| -: | ---------- | -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
|  1 | `97900c93` | `chore(deps): refresh shared inputs`                           | Already adopted: Pvl's normalized lock graph has the same `nixpkgs` and `vscode-ext` revisions, timestamps, and NAR hashes. The whole Abird lock was not copied.                                                                                              |
|  2 | `89807155` | `feat(ai): upgrade Ornith to 1.5`                              | Skipped: Abird model catalog, host configuration, and operations note; Pvl has no Ornith consumer.                                                                                                                                                            |
|  3 | `2a9ffaec` | `fix(host-manager): unify transaction recovery`                | Adopted: shared manager module, test, and Rust recovery behavior are exact; the package README retains Pvl's repository-neutral adaptations. Abird projection guide/design history was skipped.                                                               |
|  4 | `128a037f` | `docs(plans): record unified resume`                           | Skipped: Abird plan and validation events only.                                                                                                                                                                                                               |
|  5 | `046709bd` | `docs(plans): record resume integration`                       | Skipped: Abird integration event only.                                                                                                                                                                                                                        |
|  6 | `828dd32a` | `feat(host-manager): add lifecycle commands`                   | Adopted: exact generic service-placement evaluator/test, manager module/test, and Rust lifecycle implementation. Pvl root/test wiring is adapted with `servicePlacementFile = null`; `data/service-placements.json` was skipped as repository-owned topology. |
|  7 | `6e9f5da8` | `docs(host-manager): record lifecycle design`                  | Partially adopted: generic lifecycle and closeout rules were distilled into Pvl's native-control note. Abird plans, queue, events, and full control-plane document were skipped.                                                                              |
|  8 | `9a6b5263` | `feat(host-manager)!: add human output`                        | Cleanly ported as part of the final command-presentation package; README changes were adapted.                                                                                                                                                                |
|  9 | `b449990c` | `docs(host-manager): record output contract`                   | Skipped as a superseded intermediate contract; the final command-wide output note from commit 14 was adopted.                                                                                                                                                 |
| 10 | `1f26427b` | `fix(host-manager): harden move closeout`                      | Adopted: exact shared agent, manager, Nix module, and test behavior. Abird plan, projection guide, and topology-specific design history were skipped.                                                                                                         |
| 11 | `c303de1b` | `docs/plans: record move readiness`                            | Skipped: Abird acceptance and validation events.                                                                                                                                                                                                              |
| 12 | `a16de0bf` | `docs/plans: record Zulip rollout gate`                        | Skipped: Abird product rollout state.                                                                                                                                                                                                                         |
| 13 | `f16f4a6b` | `fix(flake): enforce Cargo test checks`                        | Adopted: `pkg-helper.nix` is exact; the explanatory Cargo workspace paragraph is adapted into Pvl's existing note.                                                                                                                                            |
| 14 | `4f384e17` | `feat(host-manager): unify command UX`                         | Adopted: final manager presentation implementation and generic output-UX note are exact; README/index are adapted.                                                                                                                                            |
| 15 | `8cb3affb` | `docs/plans: record command-wide UX`                           | Skipped: Abird plan events only.                                                                                                                                                                                                                              |
| 16 | `0230b402` | `style(host-manager): satisfy Clippy`                          | Cleanly ported through the final exact `presentation.rs` blob.                                                                                                                                                                                                |
| 17 | `c4ebc5f5` | `chore(projection): close zulip-tearoff-20260824`              | Skipped: Abird live projection deletion and canonical service placement.                                                                                                                                                                                      |
| 18 | `1930c685` | `feat(host-manager): add local migration mode`                 | Adopted: exact shared manager/agent/Nixbot implementation, tests, and one locally merged Cargo-lock dependency. Pvl keeps empty placement state; Abird plans and events were skipped.                                                                         |
| 19 | `c9512cb4` | `style: format host-manager docs`                              | Skipped: formatting-only changes to excluded Abird design, plan, and events.                                                                                                                                                                                  |
| 20 | `ef329ff0` | `fix(host-manager): consolidate test arguments`                | Cleanly ported in the exact manager module test.                                                                                                                                                                                                              |
| 21 | `0a1f9745` | `refactor(host-manager): group closeout deploy context`        | Cleanly ported through the final exact manager source.                                                                                                                                                                                                        |
| 22 | `4ec4719b` | `style(nixbot): format test arguments`                         | Cleanly ported with the exact Nixbot runtime-test unit.                                                                                                                                                                                                       |
| 23 | `9b4b6af4` | `fix(host-agent): preserve release evidence`                   | Cleanly ported: exact immutable release and activation-requirement lineage.                                                                                                                                                                                   |
| 24 | `eb2ee7a2` | `fix(host-manager): resume deployed closeouts`                 | Cleanly ported: exact digest-bound deployed-closeout recovery.                                                                                                                                                                                                |
| 25 | `794f4929` | `docs(host-manager): record closeout recovery`                 | Partially adopted: generic closeout/release evidence rules are in Pvl's native-control note; Abird Zulip plan and recovery evidence were skipped.                                                                                                             |
| 26 | `e2de4d2a` | `docs(zulip): close recovered transaction`                     | Skipped: Abird live recovery completion records.                                                                                                                                                                                                              |
| 27 | `aa4bdd0d` | `fix(host-control): harden migration flow`                     | Adopted: exact manifest/transfer convergence and manager lifecycle/progress/repository implementation. Generic contracts were adapted; Abird plans and incident events were skipped.                                                                          |
| 28 | `e519b05a` | `style(docs): format migration notes`                          | Skipped as a standalone source-doc formatting commit; local adopted passages are formatted independently.                                                                                                                                                     |
| 29 | `e23e69e9` | `feat(host-manager): color interactive output`                 | Adopted: exact TTY-only terminal styling and final generic output-UX note. Abird plan/event updates were skipped.                                                                                                                                             |
| 30 | `3c062c76` | `fix(opendesign): pin Node 24.18`                              | Skipped: Pvl has no OpenDesign package or consumer; remaining paths are Abird incident history.                                                                                                                                                               |
| 31 | `3fde9aaf` | `docs(plans): add private preview access`                      | Skipped: Abird product and access planning only.                                                                                                                                                                                                              |
| 32 | `69334592` | `fix(host-agent): keep runtime children held`                  | Adopted: exact host-agent, Podman/Quadlet, hold-gate, and VM/test implementation; generic Podman/native-control documentation was adopted. Abird Zulip plans were skipped.                                                                                    |
| 33 | `67917954` | `style: format migration safety docs`                          | Skipped as a standalone formatting commit; adopted local docs are formatted independently.                                                                                                                                                                    |
| 34 | `b5548cd4` | `fix(host-agent): retain readiness failures`                   | Cleanly ported: exact lossless readiness and cleanup diagnostics.                                                                                                                                                                                             |
| 35 | `82c8bb85` | `fix(zulip): stabilize migration readiness`                    | Skipped: Abird Corp Zulip hostname and readiness configuration. Generic hostname compiler support is adopted from commit 42.                                                                                                                                  |
| 36 | `c0508417` | `perf(host-manager): parallelize validation`                   | Cleanly ported: exact bounded parallel validation with deterministic ordering.                                                                                                                                                                                |
| 37 | `88875ae1` | `fix(host-manager): continue retried commands`                 | Cleanly ported: exact in-command immutable child-attempt rotation.                                                                                                                                                                                            |
| 38 | `5dc90f87` | `docs(migration): record retry readiness`                      | Partially adopted: generic validation/retry rules are in Pvl's native-control note. Abird Zulip note, work state, and events were skipped.                                                                                                                    |
| 39 | `53fb0920` | `style: format migration docs`                                 | Skipped: formatting of excluded Abird migration documentation and events.                                                                                                                                                                                     |
| 40 | `f7f6382c` | `test(host-agent): match stop diagnostics`                     | Cleanly ported with the exact host-agent regression correction.                                                                                                                                                                                               |
| 41 | `535468f9` | `fix(host-manager): isolate git subprocesses`                  | Adopted: exact repository subprocess isolation plus adapted generic documentation.                                                                                                                                                                            |
| 42 | `00a14319` | `fix(quadlet): preserve compose hostnames`                     | Adopted: exact Quadlet compiler and conversion test plus the exact shared Podman design rule. Abird migration event was skipped.                                                                                                                              |
| 43 | `0e0f8ac6` | `style: format migration event`                                | Skipped: Abird migration event formatting only.                                                                                                                                                                                                               |
| 44 | `df2f276e` | `fix(host-manager): bind projected retry jobs`                 | Cleanly ported: exact retry epoch allocation and projected activation-attempt identity.                                                                                                                                                                       |
| 45 | `a868bb96` | `fix(migration): reject stale rollbacks`                       | Adopted, then shared-hardened in both worktrees: host-agent preflight, NixOS admission, Nixbot rollback validation, and tests now also reject omitted authority; incident-specific docs/plans were skipped.                                                   |
| 46 | `75d000df` | `docs(plan): record migration repair publish`                  | Skipped: Abird publication evidence.                                                                                                                                                                                                                          |
| 47 | `51e949ac` | `fix(nixbot): skip pre-switch rollback`                        | Adopted, then shared-hardened in both worktrees: non-mutating rejection classification and rollback admission remain fail-closed when authority is absent or incomplete.                                                                                      |
| 48 | `e9358903` | `docs(plan): record rollback repair commit`                    | Skipped: Abird integration event.                                                                                                                                                                                                                             |
| 49 | `0ceb630f` | `fix(host-agent): defer isolated resources`                    | Cleanly ported: exact granular safe-deferral state, isolation proof, Nixbot health contract, tests, and VM coverage.                                                                                                                                          |
| 50 | `7aa63dd2` | `docs(plan): record granular admission`                        | Skipped: Abird implementation and validation events.                                                                                                                                                                                                          |
| 51 | `f1c89c52` | `fix(host-manager): resume failed reprepare`                   | Cleanly ported: exact failed-run retirement and reverse-synchronizing prepare epoch.                                                                                                                                                                          |
| 52 | `d3cd4db4` | `docs(plan): record reprepare repair`                          | Skipped: Abird transaction evidence.                                                                                                                                                                                                                          |
| 53 | `1f55ba08` | `fix(host-agent): prune stale deferrals`                       | Cleanly ported: exact successful-manifest deferral cleanup and non-mutating failure/preflight paths.                                                                                                                                                          |
| 54 | `9366186b` | `docs(plan): record deferral cleanup`                          | Skipped: Abird incident and live-state evidence.                                                                                                                                                                                                              |
| 55 | `a1177c16` | `fix(host-manager): finalize fresh closeouts`                  | Cleanly ported: exact fresh deployed-closeout adoption and orphaned-state rejection.                                                                                                                                                                          |
| 56 | `1be9935d` | `chore(projection): project zulip-tearoff-20260827 "seeded"`   | Skipped: Abird projection generation and service placement topology.                                                                                                                                                                                          |
| 57 | `eb573560` | `chore(projection): project zulip-tearoff-20260827 "prepared"` | Skipped: Abird runtime projection.                                                                                                                                                                                                                            |
| 58 | `4456d3c2` | `chore(projection): project zulip-tearoff-20260827 "cutover"`  | Skipped: Abird runtime projection and activation identity.                                                                                                                                                                                                    |
| 59 | `5b86a1fa` | `chore(projection): project zulip-tearoff-20260827 "prepared"` | Skipped: Abird recovery projection.                                                                                                                                                                                                                           |
| 60 | `78295c74` | `chore(projection): project zulip-tearoff-20260827 "cutover"`  | Skipped: Abird retry projection and placement.                                                                                                                                                                                                                |
| 61 | `fad7235a` | `chore(projection): close zulip-tearoff-20260827`              | Skipped: Abird canonical closeout and stable service placement.                                                                                                                                                                                               |
| 62 | `3ba9b17b` | `docs(plan): define Nix-native service moves`                  | Skipped: unimplemented Abird planning with product/topology examples.                                                                                                                                                                                         |
| 63 | `4ddc1df3` | `style(docs): format plan Markdown`                            | Skipped: Abird plan/event formatting only.                                                                                                                                                                                                                    |
| 64 | `f0bc59bf` | `style(host-agent): allow reconcile arity`                     | Cleanly ported through the final exact granular-deferral implementation.                                                                                                                                                                                      |
| 65 | `8ed010e7` | `fix(host-agent): reject incomplete rollbacks`                 | Already adopted byte-for-byte: Pvl carries the same fail-closed projection authority, Nixbot caller, module/unit tests, and phase-projection VM repair.                                                                                                       |

## Logical port units

1. Cargo and flake foundations:
   - force the exported Crane test derivation to run checks;
   - validate optional canonical service placements and expose an inert Pvl
     host-manager flake surface; and
   - merge `libc` into Pvl's existing workspace lock without copying Abird's
     repository-owned graph.
2. Host-manager lifecycle and presentation:
   - unify public resume and entity-owned `move`, `prepare`, `run`, and `close`;
   - preserve exact closeout, retry, and projection evidence;
   - support explicit local authority, truthful progress, semantic output, and
     TTY-only color; and
   - isolate Git children and validate affected hosts in bounded parallel order.
3. Host-agent convergence and admission:
   - retain release/readiness evidence and converge transient live-tree races;
   - keep native runtime child units under one exact hold gate;
   - preflight projection lineage before switches and rollbacks; and
   - safely defer only proven-isolated held resources, then prune stale
     evidence.
4. Quadlet and Nixbot integration:
   - preserve Compose hostnames as Quadlet `HostName=`;
   - package Nixbot's hostname/address tools and exact runtime test;
   - distinguish pre-switch rejection from activation failure; and
   - require current-generation admission before automatic rollback.

## Parity contract

All touched reusable source files that were previously exact are restored from
the frozen Abird tip. Pvl intentionally adapts only:

- `lib/flake/root.nix`: Pvl inputs, machine construction, and null placement /
  projection defaults remain, while the generic evaluator and output are added;
- `lib/flake/tests/default.nix`: Pvl's aggregate flake fixture remains while the
  service-placement check is registered;
- `pkgs/tools/abird-host-manager/README.md`: Pvl's repository-neutral examples
  remain while the final shared command contract is integrated; and
- `Cargo.lock`: Pvl's workspace graph remains while the manager's `libc`
  dependency is added.

Abird `data/service-placements.json`, `data/phase-projections/**`, hosts,
product packages without Pvl consumers, plans, events, secrets, and live
operational receipts are repository-owned exclusions.

The final `lib/**` and `pkgs/**` census has 398 paths common to both
repositories: 379 are byte-and-mode exact, 19 are the named Pvl-owned flake,
hardware, image, installer, kernel, locale, Nix, stack, sudo, systemd,
package-catalog, package documentation, NATS, and host-manager README
adaptations, and there are zero mode differences. Before the shared review
repair, 40 reusable paths changed in this source window were exact, three were
adapted as listed above, and OpenDesign was the sole changed source-only package
skipped for lacking a Pvl consumer.

## Shared review repair

The post-port review found that automatic rollback admission treated a missing
or incomplete incoming desired-state manifest as sufficient authority. Abird
commit `8ed010e7` and the Pvl port carry the same fail-closed repair: rollback
snapshots must contain both host-agent manifests and name every durable
projected hold or deferral. Forward closeout remains distinct and may
intentionally remove authority after release so stale deferrals can be pruned.
The Nix wrapper, Rust admission path, Nixbot rollback call, module/unit tests,
and phase-projection VM cover this boundary in both repositories.

## Validation

- Bash and Python parsing, Cargo formatting, Alejandra, Deno formatting, and
  `git diff --check` passed.
- The service-placement, host-manager, host-agent, transfer, phase-projection
  VM, Nixbot, Podman module, Quadlet conversion/generator/provider, systemd user
  lifecycle, and no-IFD lint checks built successfully.
- The repository diff lint passed from baseline `77d123d5`, including all seven
  Pvl NixOS host evaluations.
- `nix flake check --no-build` passed with import from derivation disabled.
- The shared rollback repair's module, Cargo, Nixbot, and phase-projection VM
  checks built in both repositories; both complete flake-output checks and both
  full diff lints passed after the repair.
- The complete `pvl-a1`, `pvl-l5`, and `pvl-x2` system closures built with
  import from derivation disabled.
- A final Abird fetch found zero commits after `8ed010e7`; the local Abird
  checkout, its `origin/master`, and Pvl's refreshed `abird/master` all name the
  frozen source tip. Pvl contains the same shared rollback repair byte-for-byte.
