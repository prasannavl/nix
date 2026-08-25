# Abird Post-B37 Port, 2026-08

## Scope

- Pvl baseline: `9ef174c73446229b6c66f824fa7b0dd20363b3dc` on `master`.
- Previous audited Abird source tip: `b37e3919`.
- Frozen Abird source tip: `17986f2a393a808907fcd304b498e640b5b0c39b`.
- Audit window: `b37e3919..17986f2a`, 77 commits in source order.
- Isolated landing worktree: `worktrees/abird-post-b37-port-20260825` on
  `codex/abird-post-b37-port-20260825`.
- Final landing surface: primary `/home/pvl/src/nix` worktree on `master`.

Three parallel read-only commit reviews used frozen Abird Git objects, not its
working tree. The integrated result was then reviewed cumulatively. No push,
deployment, persistent live mutation, or secret-key read occurred. The validated
83-path snapshot was promoted byte-and-mode exactly to primary `master` and
committed there as the dependency-ordered series below. The side worktree was
removed after its tracked diff, untracked-file manifest, deletion, and per-path
hashes matched primary. Its branch reference was retained.

## Per-commit ledger

|  # | Commit     | Subject                                                           | Final disposition                                                                                                                                                                                                                  |
| -: | ---------- | ----------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
|  1 | `9d91cccb` | `chore(gap3): align service versions`                             | Skipped: Gap3 host pins and its note are Abird-owned.                                                                                                                                                                              |
|  2 | `52dc01d1` | `feat(ollama): add stateless reconciliation`                      | Partially adopted: exact reusable service-module, Ollama factory/helper/tests, and cumulative Nixbot timeout behavior; skipped Abird rollout prose and model policy.                                                               |
|  3 | `d76f1e7d` | `feat(abird): upgrade to Qwen 3.8`                                | Skipped: Abird/Gap3 model catalog, host wiring, and image pins; Pvl retains its own models.                                                                                                                                        |
|  4 | `8d6b35ff` | `docs(migration): plan three-command moves`                       | Skipped: source plan and live migration state; its later reusable control-plane implementation was adopted separately.                                                                                                             |
|  5 | `813c7e14` | `feat(agent): add durable goals`                                  | Skipped: Abird application, agent, protocol, web product, and product plans are absent in Pvl.                                                                                                                                     |
|  6 | `30afa22f` | `docs(agent): record 3.4 deployment`                              | Skipped: Abird product deployment evidence.                                                                                                                                                                                        |
|  7 | `0175c0c1` | `fix(agent): restore provider readiness`                          | Skipped: Abird provider behavior, host model selection, and Gap3 limit policy.                                                                                                                                                     |
|  8 | `3466076c` | `docs(agent): record verified 3.4 rollout`                        | Skipped: Abird rollout evidence.                                                                                                                                                                                                   |
|  9 | `5e894286` | `fix(agent): omit unsupported tool choice`                        | Skipped: Abird-only provider request code.                                                                                                                                                                                         |
| 10 | `85353d7b` | `docs(agent): close phase 3.4`                                    | Skipped: repository-local plan archive and events.                                                                                                                                                                                 |
| 11 | `4b1822c0` | `docs(agent): plan phase 3.5`                                     | Skipped: Abird product roadmap state.                                                                                                                                                                                              |
| 12 | `a9f1d083` | `docs(agent): claim phase 3.5`                                    | Skipped: Abird coordination state.                                                                                                                                                                                                 |
| 13 | `4775c7ab` | `fix(agent): pin Gemma 26B`                                       | Skipped: Abird host/provider/model policy.                                                                                                                                                                                         |
| 14 | `17dda181` | `docs(agent): coordinate Phase 3 claims`                          | Skipped: Abird plans and intervention records.                                                                                                                                                                                     |
| 15 | `94420697` | `feat(agent): allow tool-free answers`                            | Skipped: absent Abird app/agent/web product.                                                                                                                                                                                       |
| 16 | `81160d0b` | `docs(agent): close evidence plan`                                | Skipped: source plan closure.                                                                                                                                                                                                      |
| 17 | `4037bc34` | `docs(agent): claim path selection fix`                           | Skipped: source coordination state.                                                                                                                                                                                                |
| 18 | `41583c70` | `fix(agent): guide bounded repository retrieval`                  | Skipped: absent Abird agent prompt/retrieval product.                                                                                                                                                                              |
| 19 | `39d92b49` | `docs(agent): close path selection fix`                           | Skipped: source plan closure.                                                                                                                                                                                                      |
| 20 | `4e6a6c28` | `docs(agent): align phase 3.5 boundaries`                         | Skipped: source plan boundaries.                                                                                                                                                                                                   |
| 21 | `9904f7a5` | `fix(nixbot): contain activation runtime`                         | Partially adopted in the cumulative exact Nixbot unit; later source hardening supersedes its implementation, while Abird operational notes were excluded.                                                                          |
| 22 | `bd915e6c` | `feat(projection): add fleet control plane`                       | Partially adopted: complete reusable flake, host-agent, host-manager, authorization, hold, projection, and tests; excluded Abird topology, migration JSON, example, plans, and events.                                             |
| 23 | `5de1b189` | `feat(nginx): add projected route adapter`                        | Cleanly ported: reusable Nginx helper, runtime candidate validation, route composition, and tests are exact.                                                                                                                       |
| 24 | `5d9da973` | `feat(zulip): adopt projected migration`                          | Skipped: Abird Zulip workload, migration inventory, and projected live state.                                                                                                                                                      |
| 25 | `cf05764f` | `fix(flake): scope checks to Linux`                               | Adopted with Pvl adaptation: Linux-only checks and portable Darwin package/dev-shell evaluation, preserving Pvl flake exports; skipped the already-excluded Web3 price-indexer package hunk.                                       |
| 26 | `0556d603` | `test(agent): align provider tool choice`                         | Skipped: Abird product test.                                                                                                                                                                                                       |
| 27 | `6292c751` | `test(app): retry WebKit readiness`                               | Skipped: absent Abird desktop app.                                                                                                                                                                                                 |
| 28 | `bba35f9a` | `docs(projection): record control-plane model`                    | Skipped: Abird design/incident/plan history; Pvl records its adopted boundary here.                                                                                                                                                |
| 29 | `bce85142` | `test(host-manager): cover mixed issuers`                         | Cleanly ported in the exact final host-manager test suite.                                                                                                                                                                         |
| 30 | `d83e0589` | `feat(nixbot): sync controller repository`                        | Partially adopted: exact Nixbot sync CLI/module/tests and exact manager integration; enabled Pvl `repos.nix.syncOnBoot`; excluded Abird host values and rollout records.                                                           |
| 31 | `c0fac9c1` | `docs(projection): record repo readiness`                         | Skipped: Abird deployment evidence and plan state.                                                                                                                                                                                 |
| 32 | `42660d10` | `style: fix markdown formatting`                                  | Skipped with its excluded source documents.                                                                                                                                                                                        |
| 33 | `b5fc3abf` | `docs(agent): plan Phase 4 Codex auth`                            | Skipped: Abird product roadmap.                                                                                                                                                                                                    |
| 34 | `ffaf473d` | `fix(gcp): enforce firewall contracts`                            | Partially adopted: all reusable GCP scripts/tests are exact; Pvl's generic playbook was adapted without Abird-edge operational claims.                                                                                             |
| 35 | `7792d910` | `fix(jitsi): harden media path`                                   | Skipped: Abird Jitsi hosts and incident policy.                                                                                                                                                                                    |
| 36 | `f27f0f22` | `fix(projection): preserve stack placements`                      | Adopted: exact reusable projection code; topology-specific test assertions were replaced with generic Pvl placement assertions; source incident docs skipped.                                                                      |
| 37 | `61790908` | `style: fix markdown formatting`                                  | Skipped with the excluded projection incident documents.                                                                                                                                                                           |
| 38 | `e302bf2d` | `fix(images): compare stable build tags`                          | Cleanly ported: reporter, tests, and aggregate check are exact.                                                                                                                                                                    |
| 39 | `73f9ed64` | `fix(jitsi): pin coordinated releases`                            | Skipped: Abird workload image policy.                                                                                                                                                                                              |
| 40 | `c836fd42` | `style: fix markdown formatting`                                  | Skipped with the Jitsi validation event.                                                                                                                                                                                           |
| 41 | `60dd32be` | `docs(jitsi): record live media repair`                           | Skipped: Abird live GCP/Jitsi incident evidence.                                                                                                                                                                                   |
| 42 | `b7f6832b` | `style: fix markdown formatting`                                  | Skipped with the Jitsi incident records.                                                                                                                                                                                           |
| 43 | `62f9f59b` | `fix(projection): scope publication checks`                       | Partially adopted: exact manager publication implementation/tests; excluded Abird incident/design/event records.                                                                                                                   |
| 44 | `2be08b28` | `perf(ci): raise controller capacity`                             | Skipped: Abird/Gondor guest capacity policy.                                                                                                                                                                                       |
| 45 | `8b3b6141` | `fix(projection): scope publish authority`                        | Partially adopted: exact reusable fetch/publish authority separation and tests; excluded Abird plans and events.                                                                                                                   |
| 46 | `44eb4c3f` | `feat(host-manager): select controller runtime`                   | Partially adopted: exact final manager runtime, capability adapter, local-run staging, runs README, and run-directory ignore hunk adapted into Pvl's `.gitignore`; excluded Abird migration/example data and adapted README prose. |
| 47 | `eed4bbef` | `refactor(nixbot): model fleet capabilities`                      | Partially adopted: exact Nixbot code/tests; Pvl inventory now names its own controller, broker, builder, and Nix registry; deployment prose adapted.                                                                               |
| 48 | `28cece3b` | `docs(projection): record capability topology`                    | Skipped: Abird topology and rollout history.                                                                                                                                                                                       |
| 49 | `5ce1f8a7` | `style: format projection events`                                 | Skipped with source events.                                                                                                                                                                                                        |
| 50 | `51a2ad99` | `style(host-manager): clarify host fallback`                      | Cleanly ported in the exact final capability adapter.                                                                                                                                                                              |
| 51 | `f5587873` | `feat(incus): support relative CPU counts`                        | Cleanly ported: shared Incus implementation, helper, docs, and tests are exact.                                                                                                                                                    |
| 52 | `df29199f` | `perf(ci): raise builder capacity`                                | Skipped: Abird/Gondor capacity policy.                                                                                                                                                                                             |
| 53 | `e1dfad45` | `style: format incus docs`                                        | Cleanly ported in the exact final Incus document.                                                                                                                                                                                  |
| 54 | `5062a9ad` | `style: fix statix warning`                                       | Cleanly ported in the exact final Incus module test.                                                                                                                                                                               |
| 55 | `41ebdd9c` | `fix(podman): publish Quadlet ready timeout`                      | Cleanly ported: production code and final projection-aware module test are exact; Pvl note/index wording was adapted.                                                                                                              |
| 56 | `3f860018` | `fix(stalwart): coordinate Quadlet recovery`                      | Partially adopted: four shared Stalwart module/helper/test paths are exact; Abird hosts and host history skipped.                                                                                                                  |
| 57 | `973e76c6` | `feat(stacks): allow dependency endpoints`                        | Skipped: absent Abird stack-projection API.                                                                                                                                                                                        |
| 58 | `3a439f57` | `fix(stacks): route CI cache to Gondor`                           | Skipped: Abird/Gondor endpoint identity and topology.                                                                                                                                                                              |
| 59 | `417463a6` | `chore(projection): project zulip-tearoff-20260824 "seeded"`      | Skipped: Abird live transaction JSON.                                                                                                                                                                                              |
| 60 | `b3540e21` | `chore(projection): project zulip-tearoff-20260824 "prepared"`    | Skipped: Abird live transaction JSON.                                                                                                                                                                                              |
| 61 | `e17f47f1` | `chore(projection): project zulip-tearoff-20260824 "rolled_back"` | Skipped: Abird retained rollback state; reusable recovery code was adopted at commit 69.                                                                                                                                           |
| 62 | `acbee1de` | `chore(deps): refresh shared inputs`                              | Already adopted by earlier Pvl input refresh; later commit 68 supersedes two shared tuples.                                                                                                                                        |
| 63 | `b8ba56ee` | `fix(nvidia): track production releases`                          | Already adopted byte-for-byte by Pvl.                                                                                                                                                                                              |
| 64 | `fbc2e1a7` | `fix(activation): skip greeter sessions`                          | Already adopted: package and patch are exact, with Pvl's overlay composition preserved.                                                                                                                                            |
| 65 | `325e5aac` | `fix(nixbot): detach activation observer`                         | Partially adopted: final bounded/fail-closed observer and tests are exact cumulatively while Pvl-owned activation documentation remains local.                                                                                     |
| 66 | `49af69d7` | `docs(tooling): record Pvl port parity`                           | Skipped: Abird-side reverse-port provenance.                                                                                                                                                                                       |
| 67 | `6aa49b29` | `docs(plans): close Pvl port audit`                               | Skipped: Abird-side plan archive and events.                                                                                                                                                                                       |
| 68 | `17fe0046` | `chore(deps): refresh shared inputs`                              | Adopted with lock-topology adaptation: exact final root Nixpkgs and VS Code extension locked tuples, preserving Pvl-only nodes.                                                                                                    |
| 69 | `4e0aa13f` | `fix(migration): repair move recovery`                            | Partially adopted: all reusable agent/manager readiness, authorization, reload-or-restart, retained-evidence code/tests are exact; Abird Zulip incident state skipped.                                                             |
| 70 | `af2992a4` | `docs(migration): record Zulip recovery`                          | Skipped: Abird retained-job incident evidence.                                                                                                                                                                                     |
| 71 | `fa4bc198` | `docs(plans): record repair integration`                          | Skipped: Abird plan materialization and events.                                                                                                                                                                                    |
| 72 | `03f5d9ec` | `fix(podman): use archive image tags`                             | Cleanly ported: compiler and conversion tests are exact; Pvl's existing backend note was adapted.                                                                                                                                  |
| 73 | `465ef431` | `fix(nixbot): retry cold cache copies`                            | Partially adopted: final Nixbot retry implementation/tests are exact; Abird endpoint and handoff history skipped.                                                                                                                  |
| 74 | `ef782430` | `docs(plans): record deploy remediation`                          | Skipped: Abird deployment plan/events.                                                                                                                                                                                             |
| 75 | `051aef21` | `test(nixbot): assert lock directory`                             | Already adopted more strongly by Pvl `9ef174c7`; the cumulative final test file remains byte-identical.                                                                                                                            |
| 76 | `a1068fb7` | `docs(tooling): record Pvl parity follow-up`                      | Skipped: Abird-side record of importing the already-present Pvl lock fix.                                                                                                                                                          |
| 77 | `17986f2a` | `docs(plans): record parity integration`                          | Skipped: Abird-side parity-plan decisions, integration events, and result updates; it changes no implementation or shared library/package path.                                                                                    |

## Pvl landing series

1. `b7ffc52d` `docs(agents): define run scratch space`
2. `66164066` `feat(flake): project stack placements`
3. `37e92954` `fix(flake): scope checks to Linux`
4. `fb6869db` `feat(ollama): reconcile model state`
5. `64ce0810` `feat(host-control): add projected moves`
6. `7f90844d` `feat(nginx): add projected route adapter`
7. `1a20a37e` `refactor(nixbot): model fleet capabilities`
8. `8c8c05e6` `feat(incus): support relative CPU counts`
9. `f02994b7` `fix(gcp): enforce firewall contracts`
10. `454c44b5` `fix(images): compare stable build tags`
11. `c30492d3` `fix(podman): publish ready timeout`
12. `b01eacda` `fix(podman): use archive image tags`
13. `d6ec8c93` `fix(stalwart): coordinate Quadlet recovery`
14. `7ef3936e` `chore(deps): refresh shared inputs`
15. `6a47b5e1` `test(lib): register shared checks`

The final documentation commit adds this ledger and its canonical index entry.

## Logical port units

1. Ollama reconciliation and readiness-timeout metadata.
2. Projection-aware host control: flake projection, hold/authorization
   materialization, Rust agent/manager runtime, controller publication,
   recovery, and Nginx route adapters.
3. Nixbot repository readiness, capability inventory, detached activation
   observation, and cold-cache retry.
4. GCP firewall contract hardening and stable image-tag reporting.
5. Relative Incus CPU capacity and final documentation/test hygiene.
6. Quadlet readiness metadata, archive-tag identity, and Stalwart recovery.
7. Shared input refresh, adapted only to Pvl's larger lock topology.

Pvl deliberately keeps `phaseProjectionDirectory = null`; the reusable control
plane is present but inert until Pvl declares repository-owned projection
documents. Pvl also keeps its own model catalogs, hosts, inventory values, flake
exports, and documentation provenance. No relevant shared commit or logical unit
remains to port from this window.

## Parity contract

At frozen source tip `17986f2a`, 374 of 393 common tracked working-tree paths
under `lib/**` and `pkgs/**` are byte-and-mode identical, with no Git mode
differences. Of the 71 common paths changed in this source window, 66 are exact
and five are deliberately adapted:

- `lib/flake/default.nix`: retain Pvl exports while applying Linux check scope.
- `lib/flake/root.nix`: retain Pvl inputs/imports and a null projection-data
  default.
- `lib/flake/tests/default.nix`: retain Pvl's local test catalog.
- `lib/flake/tests/phase-projection.nix`: replace Abird topology assertions with
  generic Pvl placement propagation coverage.
- `pkgs/tools/abird-host-manager/README.md`: omit the absent Abird Zulip fixture
  and document the generic controller/broker/builder schema.

Changed source paths absent by ownership are limited to Abird stack projection
and Gondor limits, the previously excluded Web3 price indexer, the Abird
application/agent/protocol/web product, and the Abird Gondor-to-Zulip manager
example. They have no Pvl package, module, or host consumer.

The complete path-set geometry is 672 Abird paths, 432 Pvl paths, and 393 common
paths. The 279 Abird-only paths are predominantly Abird applications, bots,
services, and stack/topology policy; the 39 Pvl-only paths are predominantly Pvl
desktop, hardware, profiles, and Codex tooling. Path absence is therefore kept
separate from byte divergence among common files.

### Nixbot parity

All eight Nixbot package/module/test files have identical full-file blobs and
Git modes at `17986f2a`:

- `lib/tests/nixbot.nix`
- `pkgs/tools/nixbot/default.nix`
- `pkgs/tools/nixbot/flake.nix`
- `pkgs/tools/nixbot/nixbot.bash`
- `pkgs/tools/nixbot/nixbot.sh`
- `pkgs/tools/nixbot/nixos-module.nix`
- `pkgs/tools/nixbot/tests/default.nix`
- `pkgs/tools/nixbot/tests/test_nixbot.py`

`nixbot.sh` is exact and executable at mode `100755`; the other seven files are
exact at `100644`. The surrounding Pvl host inventory and repository declaration
are intentionally adapted to Pvl's repository, controller, broker, builder,
registry, host, and secret ownership. Those adaptations do not change the shared
Nixbot implementation.

### Host control parity

Across the scoped host-agent/host-manager modules, packages, sources, and tests,
Abird has 68 paths. Pvl shares 67 of them: 66 are byte-and-mode exact and only
`pkgs/tools/abird-host-manager/README.md` is adapted. In particular, every
common Rust source file under both `pkgs/tools/abird-host-agent/src/**` and
`pkgs/tools/abird-host-manager/src/**` is exact, as are both package
expressions, the NixOS service modules, and all four shared host-control tests.

The README replaces Abird/Gondor concrete identities with generic
controller/broker/builder examples and removes the reference to the deliberately
excluded `examples/abird-gondor-zulip.json`. That JSON example is the sole
source-only path in this scoped control-plane comparison and encodes Abird
topology rather than reusable behavior.

The other 14 differences are established repository-owned surfaces unchanged by
this window:

- `lib/hardware.nix`
- `lib/images/default.nix`
- `lib/installer/config/default.nix`
- `lib/kernel.nix`
- `lib/locale.nix`
- `lib/nix.nix`
- `lib/stacks/default.nix`
- `lib/sudo.nix`
- `lib/systemd.nix`
- `pkgs/README.md`
- `pkgs/cloudflare-apps/README.md`
- `pkgs/cloudflare-apps/llmug-hello/README.md`
- `pkgs/manifest.nix`
- `pkgs/support/nats-streams/default.nix`

## Validation

- Alejandra, Deno Markdown formatting, Cargo formatting, Bash syntax,
  ShellCheck, direct Python suites, Cargo agent/manager tests, and
  `git diff --check` passed.
- All 33 exported `x86_64-linux` checks built successfully together, including
  the projection, migration, Podman lifecycle, Nixbot, Ollama, Incus, GCP,
  Nginx, Stalwart, and VM-backed checks.
- All seven NixOS configurations evaluated with import from derivation disabled;
  the `pvl-a1`, `pvl-l5`, and `pvl-x2` system closures built successfully.
- `nix flake check --no-build` passed, and the repository diff lint passed for
  all flake systems and all seven changed host evaluations.
