# Abird Post-FD3 Port, 2026-08

## Scope

- Pvl pre-port baseline: `60a8fee6` on primary `master`.
- Previous completed Abird audit tip: `fd3f9cda`.
- Refreshed Abird source tip: `4ecab445`.
- Audit window: `fd3f9cda..4ecab445`, 63 commits in source order.
- Staging worktree: `worktrees/abird-post-fd3-port-20260818`.

Three parallel chronological reviews inspected every commit before the shared
units were ported. No local commit was created by this session. No secret key
content was read.

## Per-commit ledger

|  # | Commit     | Subject                                             | Disposition                                                                                                   |
| -: | ---------- | --------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
|  1 | `3588b7b7` | `fix(host-manager): supersede failed jobs safely`   | Already ported by Pvl `72e75b5b`; the shared manager package remains exact.                                   |
|  2 | `29ed4f3a` | `fix(nixbot): include flock at runtime`             | Cleanly ported: `util-linux` now owns Nixbot's existing `flock` dependency.                                   |
|  3 | `5c695bb3` | `fix(ci): raise controller memory limit`            | Skipped: Abird/Gondor guest sizing and topology.                                                              |
|  4 | `20a589d3` | `style: format controller memory note`              | Skipped with the source-owned operational note.                                                               |
|  5 | `a15accec` | `fix(host-agent): bound controller deploy jobs`     | Cleanly ported: agent-owned single-host deploys set every Nixbot lane to one.                                 |
|  6 | `3f7dce1f` | `fix(host-agent): defer controller recovery safely` | Adopted: shared agent, module, and tests are exact; Abird CI host routing and source history were skipped.    |
|  7 | `4a93ae41` | `fix(ci): route controller directly to guests`      | Skipped: Abird inventory-derived Gondor routes.                                                               |
|  8 | `16315de7` | `docs: record durable Zulip rollback`               | Skipped: Abird migration evidence.                                                                            |
|  9 | `422c1b6c` | `refactor(host-manager): derive repo policy`        | Already ported by Pvl `f1559d7b`; shared manager bytes are exact.                                             |
| 10 | `336a6fdc` | `feat(agent): expand diagnostic budgets`            | Skipped: absent Abird application agent/protocol/web product.                                                 |
| 11 | `9e550787` | `fix(web): retry provider onboarding`               | Skipped: absent Abird web application.                                                                        |
| 12 | `3a8c0ae1` | `style(docs): format provider retry note`           | Skipped with Abird product documentation.                                                                     |
| 13 | `f2af2528` | `docs(agent): record budget deployment`             | Skipped: Abird deployment evidence.                                                                           |
| 14 | `e2046724` | `fix(agent): report broker failures`                | Skipped: absent Abird application provider boundary.                                                          |
| 15 | `2b5fb2af` | `style(docs): format failure note`                  | Skipped with Abird product documentation.                                                                     |
| 16 | `119a4cb3` | `docs(agent): record logging deployment`            | Skipped: Abird deployment evidence.                                                                           |
| 17 | `9a86822d` | `feat(agent): expand Gondor workspace`              | Skipped: Abird host and contained-workspace topology.                                                         |
| 18 | `04c79233` | `docs(agent): record Gondor probe`                  | Skipped: Abird live probe evidence.                                                                           |
| 19 | `7ff525ca` | `style(docs): format Gondor probe`                  | Skipped with the source probe note.                                                                           |
| 20 | `6bd2bb69` | `fix(agent): remove JSON response hint`             | Skipped: absent Abird application agent/provider.                                                             |
| 21 | `9b72ed1c` | `docs(agent): record response-hint deploy`          | Skipped: Abird deployment evidence.                                                                           |
| 22 | `d90c2ab8` | `fix(agent): accept fenced JSON actions`            | Skipped: absent Abird diagnostic provider.                                                                    |
| 23 | `800b6610` | `fix(agent): retry provider server errors`          | Skipped: absent Abird provider HTTP client.                                                                   |
| 24 | `d98c7aa0` | `feat(agent): define operational baseline`          | Skipped: Abird-only application, protocol, controller state, and lock entry.                                  |
| 25 | `35499a21` | `feat(agent): add quiesced backups`                 | Skipped: product controller backup state, not a shared host-control library.                                  |
| 26 | `9558912e` | `feat(agent): add verified restore`                 | Skipped: depends on the absent product controller schema.                                                     |
| 27 | `1afc01fe` | `feat(agent): add read-only doctor`                 | Skipped: tightly bound to absent Abird controller paths and state.                                            |
| 28 | `eeae89e5` | `feat(agent): enforce execution baseline`           | Skipped: Abird agentic execution and UI readiness plane.                                                      |
| 29 | `af010c97` | `feat(agent): expose operational status`            | Skipped: Abird product API and retained controller state.                                                     |
| 30 | `6c5a4312` | `feat(web): show operational status`                | Skipped: absent Abird web package.                                                                            |
| 31 | `b417d0ec` | `feat(agent): package operational baseline`         | Skipped: shared-looking flake hunks only export absent Abird product checks.                                  |
| 32 | `c3845223` | `test(agent): complete phase 2 acceptance`          | Skipped: Abird product acceptance tests.                                                                      |
| 33 | `160ae48a` | `docs(agent): close phase 2`                        | Skipped: Abird product plans and execution history.                                                           |
| 34 | `49c82c66` | `fix(agent): reference archived phase 2 plan`       | Skipped: Abird Gondor service wiring.                                                                         |
| 35 | `52805114` | `refactor(agent): flatten cell schema`              | Skipped: absent product cell schema.                                                                          |
| 36 | `53a479d6` | `style(docs): format phase 2 events`                | Skipped: Abird archived plan events.                                                                          |
| 37 | `7dcefca8` | `fix(agent): detect Btrfs lease owners`             | Skipped: embedded in the absent product doctor with no Pvl consumer.                                          |
| 38 | `8c8c80b0` | `docs(agent): record phase 2C rollout`              | Skipped: Abird product rollout history.                                                                       |
| 39 | `5a9d852c` | `build(flake): refresh inputs`                      | Already adopted by Pvl `8b9e61e5`; shared tuples match while lock topology remains local.                     |
| 40 | `015f082a` | `chore(ext): update pinned tools`                   | Already ported by Pvl `8b9e61e5`; all four shared package files are exact.                                    |
| 41 | `8bc2d7c7` | `docs(agentic): plan repository retrieval`          | Skipped: Abird product roadmap.                                                                               |
| 42 | `9f2cefc2` | `fix(agent): import backup receipt on restore`      | Skipped: absent product backup/restore state.                                                                 |
| 43 | `082d8513` | `docs(agentic): accept phase 3 plan`                | Skipped: Abird product plan and queue state.                                                                  |
| 44 | `d7728561` | `docs(agentic): claim phase 3.1`                    | Skipped: Abird workstream events.                                                                             |
| 45 | `0f63deaf` | `feat(agent): add repository retrieval`             | Skipped: absent Abird application agent/protocol/web vertical slice.                                          |
| 46 | `cf0201f4` | `docs(agent): record live acceptance`               | Skipped: Gondor live validation evidence.                                                                     |
| 47 | `9a61c345` | `docs(agent): close 3.1 and plan UI split`          | Skipped: Abird product archive and roadmap.                                                                   |
| 48 | `a0734e2b` | `refactor(web): separate UI and application`        | Skipped: absent Abird web package.                                                                            |
| 49 | `b9398fa7` | `docs(agentic): advance to phase 3.3`               | Skipped: Abird product planning history.                                                                      |
| 50 | `56a16bda` | `feat(agent): retain task outcomes`                 | Skipped: absent product state, protocol, web, and application packages.                                       |
| 51 | `263b0fd3` | `docs(agent): approve phase 3.3`                    | Skipped: Abird review provenance.                                                                             |
| 52 | `e13541f9` | `docs(agent): record phase 3.3 integration`         | Skipped: Abird integration provenance.                                                                        |
| 53 | `633b8c9f` | `docs(agent): record phase 3.3 rollout`             | Skipped: Abird product/topology rollout evidence.                                                             |
| 54 | `194fa712` | `docs(agent): add goal progression module`          | Skipped: Abird application roadmap.                                                                           |
| 55 | `5d511b99` | `docs(agent): claim phase 3.4`                      | Skipped: Abird plan and event state.                                                                          |
| 56 | `9eab4232` | `fix(nix): eliminate evaluation-time builds`        | Adopted: shared flake, lint, Podman, and tests are exact; durable rules were adapted to Pvl docs.             |
| 57 | `1e9d69b6` | `docs(host-control): retire legacy ownership`       | Already adopted: generic docs are exact and Pvl-specific history remains local.                               |
| 58 | `aaac33a6` | `refactor(tailscale): allow routing override`       | Already ported exactly by Pvl `2c1755dd`.                                                                     |
| 59 | `8ce262fe` | `fix(nixbot): ignore baseline timer work`           | Already ported exactly by Pvl `60a8fee6`.                                                                     |
| 60 | `971daf4a` | `docs(tooling): record pvl port audit`              | Skipped: reverse-port provenance owned by Abird.                                                              |
| 61 | `35411e36` | `feat(podman): compile Compose to Quadlet`          | Adopted: the complete shared implementation/test tree is exact; Gap3 migration plans and events were skipped. |
| 62 | `615556ea` | `docs(podman): record Quadlet landing`              | Adopted: reusable lifecycle and no-IFD guarantees updated local docs; source landing history was skipped.     |
| 63 | `4ecab445` | `fix(podman): reload rootless idmap gate`           | Adopted: shared gate, helper, and tests are exact; Gap3 Outline wiring and source events were skipped.        |

## Logical port units

1. Nixbot runtime closure: `flock` is supplied by `util-linux`.
2. Controller-safe native host-agent deployment: single-lane deploys, lock-aware
   durable recovery, typed inventory override, module options, and tests.
3. No-IFD build correctness: Cargo vendoring, generated Podman fixtures, the
   outer pre-push gate, nested lint propagation, and a dedicated regression
   check.
4. Native Quadlet framework: build-time Compose compilation, explicit runtime
   ownership, helper separation, provider transitions, and strict tests.
5. Reload-safe rootless ID-map convergence: helper churn is a no-op; only an
   effective UID/GID-map mismatch cycles the managed target.

Shared dependency pins, host-manager repository policy, Tailscale routing, and
Nixbot timer-baseline handling were already present. Abird application packages,
Gondor/Zulip topology, inventories, plans, operational events, and product-only
flake exports remain excluded.

## Parity contract

At source tip `4ecab445`, 355 of 372 common paths under `lib/**` and `pkgs/**`
are byte-identical. The 17 differences are repository-owned flake/catalog,
hardware, image, installer, kernel, locale, Nix, stack, sudo, systemd, package
documentation, Cloudflare example documentation, and NATS inventory surfaces.

The complete final `lib/podman-compose/**` tree is byte-identical, including all
seven added paths and removal of all four obsolete target-only paths. The shared
host-agent, Nixbot package, flake helper, lint entrypoints, and affected root
tests are also exact. The 29 source-window paths still absent from Pvl are the
Gap3 limit plus Abird application/protocol/web packages; none has a local
consumer.

## Validation

- Shell syntax and all seven Podman Python sources compiled cleanly.
- The complete 105-test `abird-host-agent` Rust suite passed.
- Eleven affected Nix checks built with IFD disabled: both host-agent checks,
  no-IFD lint, isolated and nested Rust flake checks, and all six Podman
  Compose/Quadlet checks.
- The full diff lint passed for all root output systems and all seven changed
  NixOS host evaluations.
- The source-window audit found 41 exact shared files, three exact deletions, 29
  absent product/topology paths, and only the two intentional Abird product
  exports in `lib/flake/{default,tests/default}.nix`.
- Final refetch left `abird/master` unchanged at `4ecab445`.
