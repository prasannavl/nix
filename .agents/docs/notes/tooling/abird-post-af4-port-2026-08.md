# Abird Post-AF4 Port, 2026-08

## Scope

- Local pre-port baseline: `d7a06dd8` on `master`.
- Previous completed Abird audit tip: `af4cf51f`.
- Refreshed Abird source tip: `bf4e406a`.
- Audit window: `af4cf51f..bf4e406a`, 86 commits in source order.
- Port worktree: `worktrees/abird-recent-port-20260803`.

Every commit was inspected in order before the reusable changes were grouped.
The final cumulative source state is authoritative when later commits replace or
correct an earlier unit. No commit was created or pushed, no live host was
changed, and no secret file was read.

## Per-commit ledger

| Commit     | Subject                                           | Disposition                                                                                                   |
| ---------- | ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| `562cadc8` | `fix(flake): honor nested project paths`          | Already adopted. Pvl carries the final nested-package path ownership behavior.                                |
| `e8b366f9` | `fix(lint): clean manifest temp dirs`             | Already adopted with Pvl's target-newer cleanup regression and status preservation.                           |
| `6564cf3a` | `refactor(data-migrator): isolate policy`         | Previously adopted, then superseded here when native host control removes `data-migrator` without fallback.   |
| `811e5c0c` | `test(flake): cover stack-set composition`        | Already adopted; the fixture remains present and passes.                                                      |
| `d89069fa` | `test(incus): align limit fixture parity`         | Already adopted at the final source behavior.                                                                 |
| `3449b618` | `docs(tooling): record pvl port audit`            | Skipped: Abird-owned history about the earlier Pvl-to-Abird audit.                                            |
| `842970d2` | `refactor(flake): simplify package manifest`      | Adopted. `lib/flake/packages.nix` is exact; the manifest and tests use the same schema with Pvl membership.   |
| `a753ca3d` | `docs(agents): define plan workflow`              | Skipped: conflicts with this repository's supplied task-management rules.                                     |
| `3baf3088` | `style(docs): format flake notes`                 | Skipped with Abird-owned planning/history docs.                                                               |
| `32fc3828` | `refactor(systemd)!: remove legacy user manager`  | Cleanly ported: module, helper, tests, docs, and nixbot compatibility path removed for native `systemd.user`. |
| `105b4411` | `docs(systemd): record manager removal`           | Adopted; reusable note exact, Pvl index adapted.                                                              |
| `aa3a295d` | `docs(agents): add Zulip migration plan`          | Skipped: Abird product migration planning.                                                                    |
| `3ca28427` | `style(agents): format migration plan`            | Skipped with that plan.                                                                                       |
| `270ecd2c` | `docs(agents): record standalone host core`       | Architecture adopted into the Pvl native-host-control note; source history skipped.                           |
| `b7a64810` | `style(agents): format standalone decision`       | Adopted through the local architecture note; operational record skipped.                                      |
| `8ca119d3` | `docs(agents): plan agentic phase 2`              | Skipped: Abird application control-plane plan.                                                                |
| `43f2cd8d` | `docs(agents): claim agentic phase 2a`            | Skipped: source-agent queue state.                                                                            |
| `de9f743e` | `docs(agents): plan phase 2a slices`              | Skipped: Abird product work partition.                                                                        |
| `f1a830ce` | `feat(protocol): add phase 2a contract`           | Skipped: Abird application protocol with no Pvl consumer.                                                     |
| `84552fa9` | `feat(agent): add local controller foundation`    | Skipped: Abird application controller.                                                                        |
| `d7844563` | `feat(agent): add durable event store`            | Skipped with the application controller.                                                                      |
| `bfb17141` | `feat(agent): secure local controller sessions`   | Skipped with the application controller/protocol.                                                             |
| `7814d8cb` | `feat(agent): stream resumable events`            | Skipped with the application event plane.                                                                     |
| `44328a91` | `feat(web): connect local controller`             | Skipped: `abird-web` is absent by design.                                                                     |
| `21a66aee` | `feat(app): manage local controller`              | Skipped: Abird Tauri app is absent by design.                                                                 |
| `d2ce9045` | `test(agent): prove phase 2a restart`             | Skipped with the application controller.                                                                      |
| `8293ae8c` | `fix(web): refresh controller sessions`           | Skipped with `abird-web`.                                                                                     |
| `77c114c2` | `fix(agent): enforce single controller owner`     | Skipped with the application controller.                                                                      |
| `298c27e6` | `fix(web): stop on rejected events`               | Skipped with `abird-web`.                                                                                     |
| `2af2616c` | `fix(agentic): recover controller restarts`       | Skipped: application/controller-only.                                                                         |
| `b39fc25d` | `fix(app): verify controller identity and health` | Skipped with the desktop app.                                                                                 |
| `c4e30f7f` | `fix(app): bound controller startup`              | Skipped with the desktop app.                                                                                 |
| `42fbd199` | `fix(agentic): require absolute data paths`       | Skipped: paths and consumers belong to the absent product stack.                                              |
| `2aadd433` | `fix(web): wait for event stream open`            | Skipped with `abird-web`.                                                                                     |
| `fffa9239` | `fix(web): negotiate controller readiness`        | Skipped with `abird-web`.                                                                                     |
| `9b8d32d9` | `fix(agent): restrict client-compatible binds`    | Skipped with the application controller.                                                                      |
| `95bffeb8` | `fix(agent): defer startup lifecycle event`       | Skipped with the application controller.                                                                      |
| `1f0aab02` | `test(agentic): automate phase 2a gates`          | Partially adopted: exact generic function-valued `extraPassthru`; application gates skipped.                  |
| `24da20a9` | `fix(web): serialize controller connect`          | Skipped with `abird-web`.                                                                                     |
| `80ad2907` | `fix(web): scope controller identity`             | Skipped with `abird-web`.                                                                                     |
| `e023c7b0` | `fix(agent): classify startup from events`        | Skipped with the application controller.                                                                      |
| `d4f75d27` | `fix(app): refresh controller status`             | Skipped with the desktop app.                                                                                 |
| `fe8fb75a` | `fix(web): clear stale readiness`                 | Skipped with `abird-web`.                                                                                     |
| `2d1a4eff` | `fix(web): cancel stale refresh callbacks`        | Skipped with `abird-web`.                                                                                     |
| `de1b5aaf` | `fix(agent): clean bootstrap on startup failure`  | Skipped with the application controller.                                                                      |
| `08f76fab` | `fix(web): reclaim event callbacks`               | Skipped with `abird-web`.                                                                                     |
| `f2ff57f4` | `test(app): cover controller status IPC`          | Skipped with the desktop app.                                                                                 |
| `2110a07d` | `fix(agent): serialize event delivery`            | Skipped with the application controller.                                                                      |
| `5e28f6a3` | `fix(agent): expire authenticated streams`        | Skipped with the application controller.                                                                      |
| `87d1e2ce` | `fix(web): serialize session refresh`             | Skipped with `abird-web`.                                                                                     |
| `e2414bed` | `fix(app): bound systemctl cleanup`               | Skipped with the desktop app.                                                                                 |
| `f59bf85e` | `fix(agent): make event shutdown sticky`          | Skipped with the application controller.                                                                      |
| `97b417e1` | `fix(web): show controller lifecycle events`      | Skipped with `abird-web`.                                                                                     |
| `6e0d7429` | `fix(agent): support hosted local sessions`       | Skipped with the application controller.                                                                      |
| `8e6c4448` | `fix(app): restart unhealthy controller`          | Skipped with the desktop app.                                                                                 |
| `df830aba` | `fix(web): retry failed desktop handshakes`       | Skipped with `abird-web`.                                                                                     |
| `1309b671` | `fix(web): restore lifecycle history`             | Skipped with `abird-web`.                                                                                     |
| `edfb09ae` | `fix(web): preserve active connection`            | Skipped with `abird-web`.                                                                                     |
| `539e8141` | `docs(agents): close phase 2a, queue 2b`          | Skipped: Abird product queue/history.                                                                         |
| `f51122d5` | `docs(plans): define phase 2B execution`          | Skipped: Abird application plan.                                                                              |
| `ded1d0e6` | `docs(plans): claim phase 2B delivery`            | Skipped: Abird product queue ownership.                                                                       |
| `61c3fc10` | `feat(host-control): add native Rust tools`       | Adopted: both cumulative Rust trees exact except two Pvl manager policy lines; root Cargo membership adapted. |
| `eec33e79` | `refactor(host-control): replace legacy stack`    | Adopted: shared modules/tests/nixbot and removals ported; Abird topology replaced by Pvl wiring.              |
| `b808a779` | `feat(nixbot): separate build identity`           | Cleanly ported byte-for-byte in nixbot and tests.                                                             |
| `892b7b1c` | `feat(registry): support role remapping`          | Cleanly ported byte-for-byte; Pvl fixture/catalog assertions adapted around it.                               |
| `6a1a9912` | `feat(migration): add Gondor host moves`          | Skipped: Abird/Gondor inventory and migration placement.                                                      |
| `2a9dcb04` | `docs(host-control): record native design`        | Architecture adopted locally; Abird rollout history/topology skipped.                                         |
| `cac5e2b8` | `style(host-control): fix formatting`             | Adopted wherever it touches shared host-control code/docs.                                                    |
| `b0a06aee` | `feat(host-manager): discover repo config`        | Cleanly ported in the native manager.                                                                         |
| `fc94cc46` | `style(docs): fix formatting`                     | Adopted on reusable host-control docs; unrelated source docs skipped.                                         |
| `2f30e96b` | `fix(host-manager): use Nixbot SSH routes`        | Cleanly ported in the native manager.                                                                         |
| `611dc35a` | `style(docs): fix host control formatting`        | Adopted on reusable native-manager docs.                                                                      |
| `24f048c8` | `fix(host-control): stream followed logs`         | Cleanly ported in manager and agent.                                                                          |
| `cc5428cf` | `docs(host-control): audit legacy parity`         | Adopted as Pvl's no-fallback boundary; source audit history skipped.                                          |
| `57a54fa0` | `fix(host-agent): harden HTTP readiness`          | Cleanly ported byte-for-byte in agent and tests.                                                              |
| `88e38adc` | `feat(host-agent): complete native operations`    | Cleanly ported byte-for-byte in agent/shared Nix integration.                                                 |
| `f9e8fb77` | `feat(host-manager): add native workflows`        | Adopted: workflow exact; logical stack default intentionally `pvl`.                                           |
| `545c8b8e` | `docs(host-control): record native workflows`     | Adopted in package docs/local ownership note; operational history skipped.                                    |
| `3d39e334` | `feat(host-agent): enforce Incus holds`           | Cleanly ported byte-for-byte.                                                                                 |
| `3de8a025` | `feat(host-manager): bind instance moves`         | Cleanly ported in manager workflow.                                                                           |
| `6187f383` | `docs(host-control): record Incus binding`        | Adopted in package docs/local contract.                                                                       |
| `e56f6a86` | `feat(host-agent): manage Incus exports`          | Cleanly ported byte-for-byte.                                                                                 |
| `cce62eec` | `feat(host-manager): add instance backups`        | Cleanly ported in manager.                                                                                    |
| `fd703cba` | `docs(host-control): record instance backups`     | Adopted in reusable package docs.                                                                             |
| `e886380a` | `docs(host-control): record backup integration`   | Adopted in package docs and summarized locally.                                                               |
| `bf4e406a` | `style: format host-control docs`                 | Adopted at final source bytes.                                                                                |

## Logical port units

1. Flake manifest v2: exact generic loader, function-valued passthru, role
   remapping, and adapted Pvl catalog/tests.
2. Native host-local control: exact `abird-host-agent`, NixOS module, transfer
   fixtures, durable holds, readiness, lifecycle, exports, backups, and
   recovery.
3. Native controller control: cumulative `abird-host-manager` and workflows,
   with only Pvl logical-stack and generated-common-module adaptations.
4. Native lifecycle integration: exact Podman Compose, tunnel, profile, flake,
   and test changes, plus common-host enablement for physical and Incus Pvl.
5. Legacy retirement: removal of `systemd-user-manager`, Bash `host-manager`,
   Python `data-migrator`, and runtime `migration-manager`, without fallback.
6. Nixbot build identity and native integration at final source bytes.
7. Documentation closeout: historical Pvl notes retained but marked superseded;
   current ownership and validation contract indexed.

## Parity contract

At `bf4e406a`, 348 of 366 paths present in both repositories under `lib/**` and
`pkgs/**` are byte-identical. The 263 source-only paths are Abird application,
bot, lab, service, stack/topology, and product-support units, plus the
intentionally absent Excalidash service. A broad directory does not make these
repository-owned products shared.

All portable implementation files introduced or changed by this window are
byte-identical except these explicit Pvl adaptations:

- `lib/flake/root.nix`: imports the host-agent module in Pvl's root flake;
- `lib/flake/tests/default.nix`: asserts the Pvl catalog around exact shared
  manifest and role-remapping behavior;
- `pkgs/manifest.nix`: retains Pvl package membership/application names;
- `pkgs/tools/abird-host-manager/src/main.rs`: defaults logical lookup to stack
  `pvl`, not `abird`; and
- `pkgs/tools/abird-host-manager/src/repository.rs`: maps generated `pvl` hosts
  to `../common/pvl.nix`, with a regression test.

The other 13 common-path differences predate this window and are
repository-owned hardware/kernel/system defaults, image/installer policy,
locale/Nix/sudo policy, stack index, package/NATS inventories, and package or
Cloudflare docs. The manager README is byte-identical at final source
formatting.

## Validation

- Confirmed `abird/master` at `bf4e406a` and audited all 86 commits after
  `af4cf51f` in source order.
- Passed 176 Rust tests: 83 agent, 75 manager-library, and 18 manager-CLI.
- Built both native packages through Nix.
- Passed 179 nixbot tests and shell syntax checks.
- Built host-agent module/transfer, isolated/nested/stack-set flake, Podman
  Compose module/native-user-lifecycle, and Incus profile checks.
- Evaluated `pvl-x2` and `pvl-vlab` with the host agent enabled.
- Passed the repository diff lint gate for all root output systems and all seven
  changed NixOS hosts, plus Cargo formatting and diff-whitespace checks.
- Confirmed retired tools remain only in negative assertions or explicitly
  superseded history.
