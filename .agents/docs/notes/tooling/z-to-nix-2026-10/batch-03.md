# Reverse batch 03 — source rows 51–75

- Global frozen rows 134–158: 25 commits, one merge, 262 first-parent path
  events / 180 unique paths. Complete ledger: `batch-03-paths.tsv`.
- Review `worktrees/z-to-nix-03` / `review/z-to-nix-03`, based on actual main
  `86b050065a17d89288588a6db9f7a4551c35face` with approved batches 01/02.
- Own delta stays staged. Separate signed logical checkpoint 03 supplies the
  batch-04 base; no main integration approval beyond batch 02.

## Commit dispositions

| Reverse / global | Source     | Disposition                             | Rationale                                                                                                                                                                     |
| ---------------- | ---------- | --------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 51 / 134         | `dd9ec9c9` | retained private product                | OAuth callback-extension parsing belongs to the absent private desktop app; no partial auth unit imported.                                                                    |
| 52 / 135         | `0591b440` | retained deployment evidence            | Private callback deployment/custody receipts do not establish destination acceptance.                                                                                         |
| 53 / 136         | `57f28f5b` | retained private product                | ChatGPT callback contract spans private app/controller; retain destination package membership.                                                                                |
| 54 / 137         | `dfcf017e` | retained deployment evidence            | Keep private callback rollout chronology local; no deployment authorized.                                                                                                     |
| 55 / 138         | `9dc38b08` | retained private product                | Bounded native errors, polling and pending-auth expiry are one private app/controller/web unit.                                                                               |
| 56 / 139         | `ca53d764` | retained private product                | Desktop-session refresh and bounded diagnostics are private credential/provider policy; no session access or activation.                                                      |
| 57 / 140         | `c45820e8` | retained historical formatting          | Private phase-4b records remain local; no documentation-index revival.                                                                                                        |
| 58 / 141         | `de3b0f6e` | already present / retained custody      | Shared plan guidance matches. Keep destination public done-capsule events and additional handoff details; historical cleanup does not authorize new deletion.                 |
| 59 / 142         | `f47922be` | retained private product                | Bounded model catalogue belongs to the private agent ChatGPT adapter.                                                                                                         |
| 60 / 143         | `43235e81` | retained merge delta                    | First-parent merge repeats the model-catalogue private unit; every path accounted without duplicate replay.                                                                   |
| 61 / 144         | `d00812b5` | retained private closeout               | Do not recreate retired phase-4b plans or import private deployment/acceptance claims.                                                                                        |
| 62 / 145         | `d45c03d5` | mixed: port shared shape test           | Adopt exact benign CLI stub only for generic normalization shape. Image/AW-source assertions belong to Abird identity fixtures; preserve Pvl checks.                          |
| 63 / 146         | `bf86f03e` | already adopted                         | Destination already gates Prism package check to x86_64. Keep registration order and newer Excalidash/Pi coverage; unrelated NVIDIA/Stalwart source obligations remain later. |
| 64 / 147         | `9e2da3fb` | adapted validation guidance             | Record shape/security and architecture-test boundaries in this batch; retain repository-specific incident history and retired docs-index layout.                              |
| 65 / 148         | `2f3c5bfd` | retained private planning               | Pinned Codex/provider ownership plan is private product policy, not generic flake authority.                                                                                  |
| 66 / 149         | `6dbd59e1` | retained coherent private unit          | Pinned Codex harness, scoped credentials, controller authority, root dependencies and breaking state reset stay together in z; no partial import or state mutation.           |
| 67 / 150         | `4d7f3b49` | retained private repair                 | Authorization-guard reuse fixes private provider deadlock, not a destination shared implementation.                                                                           |
| 68 / 151         | `2ca24b14` | retained private rollout                | Keep source deployment/recovery records local; secret changes assessed by filename only.                                                                                      |
| 69 / 152         | `3cb91e99` | retained historical formatting          | Private phase-4c records and retired coordination paths are not replayed.                                                                                                     |
| 70 / 153         | `2fe239a4` | retained private repair                 | Notification-warning suppression belongs to the absent private Codex adapter.                                                                                                 |
| 71 / 154         | `56c27589` | retained private rollout                | Source warning-fix rollout receipts are not destination acceptance.                                                                                                           |
| 72 / 155         | `936ff7d5` | retained public identity / adapted link | Preserve nix MIT/open-contribution/AI disclosure. Fix only the planning link to the retired TODO-SPEC document.                                                               |
| 73 / 156         | `75308cd7` | already adopted / superseded layout     | Current AGENTS shares signing/approval/queue conventions, differing only in repository identity. Keep TODO-SPEC retired and point contributors to live entry points.          |
| 74 / 157         | `bbd7c2f5` | retained identity / adapted link        | Do not copy private README/licensing or resurrect obsolete formatted TODO spec; current contributor pointer is the sole adaptation.                                           |
| 75 / 158         | `62c49e98` | retained private repair                 | Atomic SQLite dispatch/thread identity belongs to private agent state; no partial migration or credential operation.                                                          |

## Portable boundary

- The sole Nix delta supplies `pkgs.hello` to an evaluation-only normalization
  fixture. It never executes the fake CLI. Existing valid/public and rejected
  PKCE/confidential-app assertions remain intact; runtime default selection,
  helper behavior and non-EOL security metadata are untouched.
- Do not use benign stubs as functional/security proof or relax production
  insecure-package policy. Retain separate helper/CLI-metadata checks.
- The Prism x86_64 gate already exists; verify aarch64 absence rather than
  replaying the whole registration file and losing newer destination tests.
- Preserve MIT, public contribution/AI disclosure, exact inputs, Cargo policy,
  Pvl identity and custody records. Only repair the contributor planning link:
  TODO-SPEC is absent in both current trees; live README/queue/AGENTS exist.
- Historical rollout/state-reset commands are not authorized. No private
  provider, callback, credential, Codex harness or application unit is imported.
- New contributor-link repair needs later carry-back; no global parity claim.

## Validation

- Nine focused checks pass: normalization, helper, CLI metadata, Prism package/
  updater, shared/Pvl isolated wiring, repository config and no-IFD lint
  (job529).
- With pinned-CLI construction poisoned, the candidate shape check still
  evaluates; the old fixture fails its positive-shape assertion. Unpoisoned
  baseline also passes (job530). No production package/security override.
- x86 Prism presence, aarch64 absence and aarch64 normalization evaluation pass;
  all-system no-build evaluation passes with IFD disabled (job532; 173 checks).
- Final canonical/preservation gates precede checkpoint publication. No full
  Kanidm build, live identity acceptance, ARM/Darwin execution or deployment is
  implied.

## Path dispositions

- adapted-current-link: 2.
- already-adopted-architecture-gate: 1.
- already-present: 8.
- ported-shape-test: 1.
- retained-local-evidence: 22.
- retained-repository-ownership: 70.
- retained-secret-boundary: 7.
- retired-layout/history: 151.
