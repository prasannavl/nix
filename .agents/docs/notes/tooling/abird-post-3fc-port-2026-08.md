# Abird Post-3fc Port, 2026-08

## Scope

- Pvl pre-audit tip: `23e8741caab8e03689f78a429a8edbc6baf3dedc` on the primary
  `master` worktree.
- Previous completed Abird audit tip:
  `3fcaea2cdd7af64ff229f12dfc0304da943ba6f7`.
- Frozen Abird primary-worktree tip: `22e85790ba8c0e18ae2a313246a16ee164c04835`.
- Audit window: `3fcaea2c..22e85790`, 42 commits in source order.
- Landing surface: the primary `/home/pvl/src/nix` worktree on `master`.

Both repositories were clean before the audit. Abird local `master`,
`origin/master`, and the live GitHub ref agreed at the frozen source tip. Three
parallel read-only reviews classified the complete window before the shared path
audit.

## Per-Commit Ledger

|  # | Commit     | Subject                                           | Content and final disposition                                                                                                                                                                          |
| -: | ---------- | ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
|  1 | `efd02a1a` | `test(host-manager): provide jq to checks`        | Already ported byte-for-byte in Pvl `1b62cb8f`: add `pkgs.jq` to the shared host-manager test closure. The final `100644` blob is `3907a518`; the stable patch ID also matches.                        |
|  2 | `9a308b1f` | `feat(agent): add model-directed goals`           | Skipped: adds the Abird protocol, agent orchestration/store/provider, web/UI, desktop/browser tests, and phase execution record as one product vertical. Pvl owns none of these packages or consumers. |
|  3 | `9b228aea` | `fix(agent): clarify evaluator evidence`          | Skipped: requires bounded result evidence and permits source-free task/run evidence in the Abird automatic-goal evaluator.                                                                             |
|  4 | `815275d6` | `fix(agent): constrain evaluator output`          | Skipped: adds the strict goal-decision JSON schema and structured provider response plumbing to Abird agent/provider code.                                                                             |
|  5 | `e02601d3` | `fix(agent): prioritize goal completion`          | Skipped: changes Abird evaluator prompt policy to prefer completion when retained successful evidence satisfies the contract.                                                                          |
|  6 | `86c022ea` | `fix(agent): constrain repeated goal tasks`       | Skipped: excludes attempted objectives from Abird evaluator `next_task` schema output.                                                                                                                 |
|  7 | `b0fa7e9d` | `fix(agent): focus evaluator projection`          | Skipped: makes retained evidence exact, gates completion on successful evidence, and refocuses the Abird evaluator projection.                                                                         |
|  8 | `44634fbe` | `fix(agent): compare goal contracts semantically` | Skipped: changes Abird evaluator contract comparison from literal wording to substantive requirement satisfaction.                                                                                     |
|  9 | `7f7e1d40` | `fix(agent): give tasks goal contract`            | Skipped: threads the automatic goal contract through Abird cell manifests, execution, provider metadata, and model instructions.                                                                       |
| 10 | `e7b3a887` | `fix(agent): repair invalid goal decisions`       | Skipped: repairs one invalid/repeated evaluator decision while retaining provider accounting.                                                                                                          |
| 11 | `df9ce842` | `fix(agent): retain goal contract across tools`   | Skipped: restores the current objective and completion contract after Abird repository tool calls.                                                                                                     |
| 12 | `8dd448b6` | `fix(agent): prioritize user access evidence`     | Skipped: makes Abird repository evidence lookup prefer the exact requested user module.                                                                                                                |
| 13 | `4110cba9` | `fix(agent): retain plan navigation intent`       | Skipped: derives Abird plan-navigation requirements and phase labels from the objective and completion contract.                                                                                       |
| 14 | `ddb12b1b` | `fix(agent): focus plan evidence search`          | Skipped: requires the exact contract identifier during Abird indexed-plan evidence searches.                                                                                                           |
| 15 | `bf33c34d` | `fix(agent): reject unrelated goal protocol`      | Skipped: rejects evaluator tasks that introduce unrelated goal-protocol operations.                                                                                                                    |
| 16 | `12d981b6` | `fix(agent): retain automatic goal context`       | Skipped: adds optional goal-objective context to Abird cell manifests and provider navigation prompts.                                                                                                 |
| 17 | `2503b720` | `fix(agent): ground evaluator next tasks`         | Skipped: lexically grounds Abird evaluator next tasks in retained context and rejects unrelated contamination.                                                                                         |
| 18 | `326b9cc3` | `fix(agent): repair accounted empty turns`        | Skipped: treats empty or unsupported provider replies as accounted invalid turns and repairs one Abird broker turn.                                                                                    |
| 19 | `4b771e1c` | `fix(agent): prioritize broker corrections`       | Skipped: appends Abird broker corrections last with an explicit correction marker.                                                                                                                     |
| 20 | `ce808c49` | `fix(agent): reject additive task repeats`        | Skipped: rejects additive and paraphrased repeats of previously attempted Abird objectives.                                                                                                            |
| 21 | `7f764ecf` | `fix(agent): enforce multi-step contracts`        | Skipped: tells the Abird evaluator to enforce literal attempt ordering and multi-attempt evidence.                                                                                                     |
| 22 | `0b462d4a` | `fix(agent): repair repeated tool turns`          | Skipped: canonicalizes Abird cell actions and repairs one already-completed repository tool call.                                                                                                      |
| 23 | `be3e3bc6` | `fix(agent): reject cross-goal tasks`             | Skipped: tightens retained-context overlap for Abird evaluator task admission.                                                                                                                         |
| 24 | `ed3db63f` | `fix(agent): bind explicit multi-step goals`      | Skipped: removes early completion from the Abird evaluator schema when a contract requires another attempt.                                                                                            |
| 25 | `b1eae614` | `fix(agent): repair early completion`             | Skipped: makes invalid early-completion repair require an Abird `next_task`.                                                                                                                           |
| 26 | `d29fc33a` | `test(agent): await both controllers`             | Skipped: stabilizes an Abird crossed-controller operational test by awaiting both controller endpoints.                                                                                                |
| 27 | `a704510f` | `fix(agent): reject shortened task repeats`       | Skipped: detects both extended and shortened repeats using normalized objective words.                                                                                                                 |
| 28 | `f0b51ed9` | `fix(agent): align repeated-task repair`          | Skipped: makes repeat repair contract-aware and require distinct later Abird work.                                                                                                                     |
| 29 | `17b88896` | `fix(agent): forbid premature completion`         | Skipped: adds a contract-specific early-completion prohibition to the Abird evaluator prompt.                                                                                                          |
| 30 | `1f195033` | `chore(agent): trace evaluator rejection`         | Skipped: traces Abird evaluator rejection kinds, causes, and accounted invalid turns.                                                                                                                  |
| 31 | `dfa8974e` | `chore(agent): trace next-task rejection`         | Skipped: emits cause-specific warnings for malformed or invalid Abird next-task proposals.                                                                                                             |
| 32 | `39b75d8c` | `fix(agent): accept bounded task paraphrases`     | Skipped: admits grounded paraphrases while still rejecting foreign Abird phase labels.                                                                                                                 |
| 33 | `2ec11e35` | `fix(agent): bind evaluator repair terms`         | Skipped: transitional Abird repair prompt requiring an exact completion-contract term, refined by later commits.                                                                                       |
| 34 | `1ceb5d15` | `fix(agent): make evaluator repair exact`         | Skipped: embeds the exact Abird completion contract into evaluator repair instructions.                                                                                                                |
| 35 | `f8092b20` | `fix(agent): require missing goal step`           | Skipped: exposes only `next_task` and rejects `blocked` when an Abird contract has a known missing later attempt.                                                                                      |
| 36 | `0dfaffb0` | `test(agent): pin live WAL snapshot`              | Skipped: pins the Abird Doctor test's live SQLite WAL snapshot with a held read transaction.                                                                                                           |
| 37 | `97a485fb` | `fix(agent): bind explicit next objective`        | Skipped: parses an explicit next objective from the Abird contract and enforces exact schema, validation, and repair equality.                                                                         |
| 38 | `ab729f74` | `fix(agent): default invalid evidence safely`     | Skipped: conservatively classifies an accounted invalid evidence turn as repository evidence while preserving Abird provider readiness.                                                                |
| 39 | `0edca8f5` | `docs(agent): record phase 3.5 deployment`        | Skipped: Abird Gondor deployment, live acceptance, incident, validation, plan, and event evidence.                                                                                                     |
| 40 | `81ba5d76` | `docs(agent): close phase 3.5`                    | Skipped: moves Abird phase 3.5 work into its done/archive plan hierarchy and records closeout.                                                                                                         |
| 41 | `a3c59d9e` | `style(docs): apply Markdown formatting`          | Skipped with the 52 Abird phase-plan, event, result, and index documents it reformats.                                                                                                                 |
| 42 | `22e85790` | `test(agent): clean immutable snapshots`          | Skipped: restores permissions before dropping Abird read-only repository-snapshot test fixtures.                                                                                                       |

Commits 2 through 38 and 42 touch only `pkgs/apps/abird-app`,
`pkgs/srv/abird-agent`, `pkgs/support/abird-protocol`, and `pkgs/web/abird-web`.
Those four product packages, their workspace members, flake exports, and
consumers are absent from Pvl. Their patch IDs are also absent from Pvl
`master`; this is an intentional ownership boundary rather than missed
shared-package parity.

`pkgs/srv/abird-agent` is the Abird application controller and is distinct from
the shared `pkgs/tools/abird-host-agent`. The host manager depends on the
latter. At this boundary Pvl and Abird carry the complete host-agent package at
the same tree hash, `f97ddff90ae522967518951de33ab852fc068b02`; no host-agent
commit was skipped.

## Logical Units

1. Shared host-manager test closure (`efd02a1a`): already present byte-for-byte
   in Pvl and validated as the package test dependency for repository fixtures
   that execute `jq`.
2. Model-directed goals vertical (`9a308b1f`): Abird protocol types, durable
   agent store/orchestration/provider behavior, web/application/UI controllers,
   desktop/browser tests, and an explicitly incompatible product-state
   transition. Skipped as an inseparable Abird product unit.
3. Evaluator, broker, provider, and operational-test hardening
   (`9b228aea..ab729f74`, plus `22e85790`): skipped with the absent product
   packages they exclusively test and consume.
4. Phase 3.5 deployment and closeout records (`0edca8f5..a3c59d9e`): skipped as
   Abird operational and planning history.

No new reusable `lib/**`, systemd-user-manager, Incus, services, flake helper,
or present-in-both-repositories package change exists in this window.

## Parity Contract

The sole source-window path common to both repositories is
`pkgs/tools/abird-host-manager/default.nix`. Pvl and Abird have the same
`100644` mode, `3907a51816f40d7199219691c4ec5c4e3bbd360e` blob, and
`9f90d91a6cd73c5759b10f7851cc03275d944499` stable patch ID for the `jq`
dependency change.

The complete frozen-tip census still has 402 paths common under tracked `lib/**`
and `pkgs/**`: 382 are byte-and-mode exact, 20 are the previously named
Pvl-owned flake, fixture, hardware, image, installer, kernel, locale, Nix,
stack, sudo, systemd, package-catalog, package-documentation, NATS, and
host-manager README adaptations, and there are zero mode differences. No shared
path regressed in this window.

## Validation

- The Pvl host-manager package check builds successfully with import from
  derivation disabled.
- No-IFD evaluation of the complete Pvl check-name set succeeds.
- The source window changes no shared `lib/**` path and only the already-exact
  host-manager package definition under common `pkgs/**`.
- Three independent commit-slice reviews found no missing Pvl consumer or
  portable logical unit beyond the already-adopted `jq` dependency.
- No implementation file required editing in Pvl, and no commit or push was
  performed during this audit.
