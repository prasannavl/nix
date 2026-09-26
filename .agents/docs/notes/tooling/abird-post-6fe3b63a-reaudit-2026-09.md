# Abird parity re-audit after `6fe3b63a`, 2026-09-26

## Boundary

- Previous recorded shared boundary: `857ac6eb` (frozen by
  [the post-`28631f93` audit](./abird-post-28631f93-audit-2026-09.md)).
- Configured `abird/master` tip at audit: `6fe3b63a`
  (`fix(ai): avoid false
  worker failure on restart`).
- Pvl target: `master` at `d77d1773`, clean working tree.
- Audit window: `857ac6eb..6fe3b63a`, 36 linear commits, grouped into the AI
  endpoint/projection series, two memory-doc commits, and the Nix-native
  projection series plus its AI follow-up.
- Landing mode: read-only verification. No shared implementation was unported,
  so no port commit was authored; no push, deployment, service restart, image
  pull, database query, or migration was performed. Secret-key files were
  neither listed nor read.

## Result

Every shared implementation unit in the window is byte- and mode-identical in
Pvl. There is no unported change and no POSSIBLE GAP.

Final filesystem comparison of tracked paths under `lib/**`, `pkgs/**`, and
`scripts/**`: 571 common paths, 553 identical (content plus mode), 18 explained
content differences, and 0 mode differences. The +1 common/+1 exact over the
projection note's 570/552 is the post-note `6fe3b63a` port
(`lib/services/model-reconciler/dispatch.sh` and its suite).

The 18 differences are unchanged Pvl-owned divergences: external-source pins and
update policy (`lib/ext/nvidia/**`, `lib/ext/pi/**`,
`lib/ext/vscode/sources.nix`), hardware/locale/network/sudo/systemd/installer
policy (`lib/hardware.nix`, `lib/locale.nix`, `lib/network.nix`, `lib/sudo.nix`,
`lib/systemd.nix`, `lib/installer/config/default.nix`), repository identity
(`lib/flake/repo-checks.nix`, `lib/flake/tests/configuration-family.nix`), and
package docs/manifest (`pkgs/manifest.nix`, `pkgs/README.md`,
`pkgs/cloudflare-apps/**`). No changed generic source path is unaccounted for.

## Batch 1 - AI endpoint and projection series `a13e4394..6fa0b6fb` (24 commits)

| Commit     | Subject                                             | Disposition | Notes                                                                                                                         |
| ---------- | --------------------------------------------------- | ----------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `a13e4394` | feat(ai): add shared projection lib                 | ported      | Shared `lib/services/ai/{backends,catalog,module,projection}.nix`, tests, and `lib/tests/default.nix`; Pvl mirror `c814975a`. |
| `f49214b7` | refactor(abird-srv): derive ai projections          | skipped     | `hosts/abird-srv/**` identity only.                                                                                           |
| `be68effd` | docs(ai): record composition review                 | skipped     | Source docs.                                                                                                                  |
| `85cb4250` | fix(ai): unify model policy resolution              | ported      | Shared AI and `llama-router` policy; Pvl mirror `e804041e`.                                                                   |
| `7a16a5cf` | fix(prism): harden package and updater              | ported      | `lib/ext/prism-llama-cpp/**`, updater tests; Pvl mirror `53ebe2d5`.                                                           |
| `6a11b7ce` | fix(nats): fail closed on stream lookup             | ported      | `pkgs/support/nats-streams/default.nix`, shared test registration; Pvl mirror `d84a6df5`.                                     |
| `c7564603` | test(modules): cover Abird registry                 | skipped     | Abird identity test (`lib/flake/tests/abird/**`).                                                                             |
| `ba7d22fc` | docs(ai): record review hardening                   | skipped     | Source docs.                                                                                                                  |
| `62ab3da5` | docs(ai): record Abird integration                  | skipped     | Source docs.                                                                                                                  |
| `9907774c` | style: format AI review docs                        | skipped     | Source docs formatting.                                                                                                       |
| `873e936d` | fix(ai): consolidate catalog policy contract        | ported      | Shared AI catalog/module/policy; Pvl mirror `2158059f`.                                                                       |
| `0cf513e6` | refactor(abird-srv): consume ai moduleConfig bridge | skipped     | `hosts/abird-srv/**` identity only.                                                                                           |
| `a7e1b624` | docs(ai): record policy contract consolidation      | skipped     | Source docs.                                                                                                                  |
| `2d63c02b` | docs(memory): advance to dispatch enforcement       | skipped     | Source plan history.                                                                                                          |
| `d2088b72` | fix(ai): retire qwen36-35b-a3b from shared catalog  | ported      | Shared catalog and tests; the retirement is folded into Pvl `87b61ab0`; neither tip carries `qwen36-35b-a3b`.                 |
| `243dd77a` | feat(ai): add consumer endpoint projection          | ported      | Shared AI module/projection; Pvl mirror `2439daec`.                                                                           |
| `16c0da28` | docs(tooling): record git stash and signing notes   | skipped     | Source docs.                                                                                                                  |
| `a0754ba7` | docs(parity): record Pvl post-c6a4a182 port         | skipped     | Source ledger.                                                                                                                |
| `0b2e3fdf` | feat(ai): list llama.cpp endpoints in corp UIs      | adopted     | Shared endpoint view ported earlier; Abird corp UI consumers skipped. Pvl host consumers are authored separately.             |
| `80f90fef` | feat(ai): reshape consumer endpoint projection      | ported      | Shared AI module/projection and tests; Pvl mirror `074f51c8`.                                                                 |
| `26bcdd52` | refactor(ai): consume endpoint view across services | adopted     | Abird corp/data host consumers skipped; Pvl host consumers are ported as `ff7c9b05`.                                          |
| `9e459632` | style(docs): fix deno fmt drift                     | skipped     | Source docs formatting.                                                                                                       |
| `9bb2886c` | style(ai): drop redundant parens                    | ported      | Shared AI test file; Pvl mirror `c0c3ba3c`.                                                                                   |
| `6fa0b6fb` | docs: label fenced code blocks                      | skipped     | Source docs formatting; carried into Pvl docs as `fb570576`.                                                                  |

No shared unit was dropped: every commit either maps to an exact shared
implementation path or is source-only identity/docs.

## Batch 2 - Memory docs `bc0f4c34`, `690807d8` (2 commits)

Both commits are source workstream memory/plan records with no `lib/**`,
`pkgs/**`, or `scripts/**` change. Skipped as source-owned history.

## Batch 3 - Nix-native projection and follow-up `06b05f18..6fe3b63a` (10 commits)

The projection note records the detailed dispositions for `06b05f18..5204195a`.
This audit reconfirms final parity and adds the `6fe3b63a` follow-up:

| Commit     | Subject                                        | Disposition | Notes                                                                                                                                                        |
| ---------- | ---------------------------------------------- | ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `06b05f18` | feat(host-control): add Nix projections        | ported      | Shared Nix/Rust/Bash/tests/validation/account API; only `lib/flake/repo-checks.nix` and the `configuration-family.nix` fixture differ (repository identity). |
| `939119c4` | feat(host-control): merge Nix projections      | skipped     | Merge metadata and Abird coordination records only.                                                                                                          |
| `379fb331` | fix(projections): admit schema rollout         | ported      | Generic projection/admission fixes and tests; Abird family declarations excluded.                                                                            |
| `8a15aad2` | refactor(secrets): compose Abird scopes        | skipped     | Abird secret/topology composition (`data/secrets/**`, `config/abird/**`); Pvl recipients adapted separately.                                                 |
| `af3c6e72` | refactor(zulip): localize service module       | skipped     | Zulip and affected Abird host topology absent in Pvl.                                                                                                        |
| `1b3b968e` | style(docs): fix format drift                  | skipped     | Carried through accepted shared design docs; plan-event history excluded.                                                                                    |
| `cb910ac6` | refactor(projection): retire legacy move paths | ported      | Shared Nix/host-agent/host-manager/tests; Abird declarations and journals excluded.                                                                          |
| `0f14b1b5` | docs(plan): record projection retirement       | skipped     | Source workstream history.                                                                                                                                   |
| `5204195a` | fix(host-control): clean admission output      | ported      | Shared host-agent/manager/Nixbot/tests/design contract byte-exact.                                                                                           |
| `6fe3b63a` | fix(ai): avoid false worker failure on restart | ported      | Byte-identical shared files to Pvl `466c04e0`; only Pvl's extra identity note `ollama-model-reconciler-2026-09.md` differs.                                  |

## Out-of-scope observations

- `lib/systemd-user-manager/**` does not exist at either tip. Abird removed it
  earlier (`32fc3828`); Pvl already retired it
  ([legacy manager removal](../services/native-user-graph-legacy-manager-removal-2026-07.md)).
  Nothing to port.
- `lib/services/excalidash/**`, `pkgs/tools/postgres-queue/**`,
  `pkgs/tools/sqlite-queue/**`, `pkgs/examples/edi-ast-parser-rs/**`, and
  `lib/sway.nix` are Abird-only paths already documented as excluded ownership
  boundaries in earlier audits; reconfirmed here.
- The `worktrees/ai-artifact-serving-profiles-20260923` worktree carries a Pvl
  feature overlay (`refs/worktree-backups/20260926/ai-artifact-resync-pvl/*`)
  that is not an Abird `master` port and was left untouched.
