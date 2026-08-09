# Abird Post-BF4 Port, 2026-08

## Scope

- Local pre-port baseline: `ebea0b50` on primary `master`.
- Previous completed Abird audit tip: `bf4e406a`.
- Refreshed Abird source tip: `fd3f9cda`.
- Audit window: `bf4e406a..fd3f9cda`, 130 commits in source order.
- Work was performed directly in the primary worktree as requested.

Three parallel 43-commit reviews classified the initial source window before
cumulative shared units were ported; a follow-up review classified the
one-commit tail found by the final refetch. Secret path names were listed where
needed to classify topology, but no `data/secrets/**/*.key` file content was
read.

## Per-commit ledger

|   # | Commit     | Subject                                           | Disposition                                                                                                                               |
| --: | ---------- | ------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
|   1 | `be3a27c3` | `fix(deploy): handle held cold targets`           | Cleanly ported byte-for-byte: hold-aware cold-target deploy health, deferred candidate-owner image pulls, Podman tests, and Nixbot tests. |
|   2 | `beeb382b` | `feat(zulip): add dedicated migration target`     | Skipped: Abird Zulip host, inventory, migration manifest, limits, and encrypted-secret topology.                                          |
|   3 | `08fbbd47` | `feat(host-control): add held data wipe`          | Cleanly ported: durable hold-checked data wipe across native agent, manager workflow, CLI, tests, and package docs.                       |
|   4 | `565ed4c4` | `style: format migration docs`                    | Adapted: retained final formatting and reusable Podman/host-control rules; skipped Abird migration plans and events.                      |
|   5 | `ba3a2066` | `style(secrets): remove unused binding`           | Skipped: Abird secret-manifest cleanup; no secret contents were read.                                                                     |
|   6 | `0560b369` | `fix(host-agent): resolve runuser provider`       | Cleanly ported: host-agent wrapper now resolves `runuser` from `util-linux`, with module coverage.                                        |
|   7 | `f9d1301c` | `feat(host-control): unify log output modes`      | Cleanly ported: symmetric text/JSON snapshot and follow modes in agent and manager.                                                       |
|   8 | `55588e34` | `feat(host-manager): infer repository moves`      | Adopted: exact cumulative manager inference logic plus Pvl root `system.configurationRevision`; retained Pvl stack and module policy.     |
|   9 | `060ee874` | `style(docs): apply formatter`                    | Adapted formatting on locally owned host-control documentation; skipped source operational history.                                       |
|  10 | `46ceab96` | `fix(host-agent): harden deferred jobs`           | Cleanly ported: consumable deferred-job wakeups, bounded broker socket paths, and early agent failure reporting.                          |
|  11 | `b60b7809` | `feat(host-manager): report move progress`        | Cleanly ported: durable manager move-progress reporting.                                                                                  |
|  12 | `4c0c7663` | `test(host-manager): publish fixtures atomically` | Cleanly ported: atomic Nix and generated-config fixture publication.                                                                      |
|  13 | `96268f92` | `docs(migration): record seed runtime blocker`    | Skipped: Abird live Zulip seed blocker history.                                                                                           |
|  14 | `2fc72e06` | `style(docs): apply formatter`                    | Skipped with the source-only migration history it formats.                                                                                |
|  15 | `5a656e71` | `fix(host-control): pin broker endpoints`         | Cleanly ported: authenticated broker endpoint pins and fail-closed retry enrichment.                                                      |
|  16 | `607d648e` | `feat(host-manager): resume matching moves`       | Cleanly ported while retaining the Pvl logical-stack default: matching pre-prepare moves resume safely.                                   |
|  17 | `1d9e8c2e` | `docs(migration): record retry safety`            | Source history skipped; durable retry/pinning rules summarized in the Pvl host-control note.                                              |
|  18 | `f87d0051` | `fix(host-agent): derive SSH host key path`       | Cleanly ported: derive or explicitly configure the OpenSSH Ed25519 host public-key path.                                                  |
|  19 | `0ab43ef5` | `docs(migration): record host key path fix`       | Source event skipped; the reusable host-key-path rule is documented locally.                                                              |
|  20 | `4bee80f8` | `feat(protocol): define contained diagnostic`     | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  21 | `8d70dfd6` | `feat(agent): persist diagnostic state`           | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  22 | `e66dbc8d` | `feat(agent): add provider boundary`              | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  23 | `cee2208b` | `feat(agent): add contained cell`                 | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  24 | `ac26ce69` | `feat(agent): add rootless cell broker`           | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  25 | `c1609ed7` | `feat(agent): orchestrate diagnostics`            | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  26 | `b8589964` | `feat(agent): expose diagnostic API`              | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  27 | `d483f42b` | `feat(web): add contained diagnostic`             | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  28 | `be4293cf` | `test(agent): prove contained delivery`           | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  29 | `bb0c7e29` | `fix(agent): close Phase 2B review gaps`          | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  30 | `3a381dc5` | `fix(agent): remove README diagnostic dependency` | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  31 | `047b9595` | `fix(agent): report proven cell lifecycle`        | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  32 | `bc93b7ed` | `fix(agent): retain diagnostic initiator`         | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  33 | `98897bca` | `test(agent): cover diagnostic crash gates`       | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  34 | `82216ba1` | `feat(agent): add diagnostic cancellation`        | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  35 | `bd02ed68` | `fix(agent): fail closed on create cancellation`  | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  36 | `d5872eb0` | `fix(agent): preserve diagnostic handoff`         | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  37 | `19074b86` | `fix(web): accept successful JSON responses`      | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  38 | `85265e5c` | `fix(agent): advertise cell schema 2`             | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  39 | `c363257c` | `fix(agent): make cell runtime optional`          | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  40 | `819036e4` | `fix(agent): pair controller and cell image`      | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  41 | `63787ded` | `fix(agent): fail closed on stale run state`      | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  42 | `025b8fbc` | `fix(agent): persist cancellation intent`         | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  43 | `c2bcf41c` | `fix(agent): make task commits cancellation-safe` | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  44 | `72bf81ed` | `fix(agent): retain model diagnostics`            | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  45 | `00d8f649` | `fix(agent): bound diagnostic prompts`            | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  46 | `7664adeb` | `fix(web): refresh provider health`               | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  47 | `a2850eb6` | `fix(ci): export browser check`                   | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  48 | `f7b6b792` | `fix(agent): fail closed on create cancel`        | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  49 | `9e60c331` | `fix(agent): persist execution recovery`          | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  50 | `4ebad246` | `fix(agent): align diagnostic workspace view`     | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  51 | `cb5b4708` | `fix(web): abort stale session refreshes`         | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  52 | `c7e86499` | `fix(agent): accept terminalizing cancel retries` | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  53 | `f6f04442` | `fix(agent): recover accepted cancellations`      | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  54 | `3f5fdfe3` | `fix(web): preserve terminal cancellation state`  | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  55 | `a39a29ce` | `fix(app): separate lifecycle from readiness`     | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  56 | `c6e3daf6` | `fix(agent): prioritize cleanup failures`         | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  57 | `c7e0fd2f` | `fix(agent): verify diagnostic evidence`          | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  58 | `c322be8c` | `fix(web): invalidate lost authority`             | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  59 | `92a46d54` | `fix(agent): align readiness with execution`      | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  60 | `2b3f4745` | `fix(agent): close admission cancel window`       | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  61 | `e6b4a32e` | `fix(agent): arbitrate start cancellation`        | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  62 | `e21934ae` | `fix(web): constrain controller endpoints`        | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  63 | `207db5bd` | `fix(agent): reject zero network ports`           | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  64 | `9ded0e97` | `fix(agent): fail close artifact staging`         | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  65 | `cd5373c9` | `fix(agent): fail result persistence errors`      | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  66 | `fafd7669` | `fix(agent): verify cell observations`            | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  67 | `f5af5ed6` | `fix(agent): bound command output draining`       | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  68 | `80bcade2` | `fix(web): refresh readiness from run events`     | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  69 | `85fba79f` | `fix(agent): await bounded output EOF`            | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  70 | `b7f43cd9` | `fix(web): preserve live SSE state`               | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  71 | `930491f2` | `fix(nix): restrict agent to Linux`               | Partially adopted: export NixOS modules from the unfiltered package set; skipped Abird product packages/check assertions.                 |
|  72 | `e3e2c86b` | `fix(agent): preserve cancellation responses`     | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  73 | `d49033fb` | `fix(agent): fail approval persistence errors`    | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  74 | `e5231af4` | `fix(agent): fail cancelled persistence`          | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  75 | `a75ce4ec` | `fix(agent): honor cancellation on fallback`      | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  76 | `bb11bda8` | `fix(agent): decouple outbox delivery`            | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  77 | `eb3eebe9` | `fix(agent): recover missed outbox wakes`         | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  78 | `811c752b` | `refactor(agent): trim store results`             | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  79 | `4ec082bc` | `test(agent): use production store paths`         | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  80 | `be84be87` | `refactor(agent): flatten provider errors`        | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  81 | `096154b2` | `refactor(agent): return provider tuple`          | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  82 | `63f6b5f3` | `refactor(app): simplify discovery result`        | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  83 | `cbc48c49` | `refactor(web): share provider readiness`         | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  84 | `b63efd09` | `refactor(agent): remove config setters`          | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  85 | `00707606` | `refactor(agent): rely on lock RAII`              | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  86 | `7d2c738d` | `refactor(flake): dedupe promoted checks`         | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  87 | `ef4834f6` | `fix(agent): isolate workspace secrets`           | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  88 | `2cc99712` | `fix(agent): terminalize runs on shutdown`        | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  89 | `558cb030` | `test(app): match controller stop timeout`        | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  90 | `9fefd780` | `fix(agent): bound diagnostic shutdown`           | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  91 | `4138282d` | `fix(agent): share controller shutdown deadline`  | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  92 | `6d44cfe6` | `fix(agent): preserve shutdown cleanup window`    | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  93 | `aa113842` | `fix(agent): validate persisted workspaces`       | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
|  94 | `b16e4ffb` | `docs(plans): close Phase 2B`                     | Skipped: Abird product plan, queue, event, or operational-history document.                                                               |
|  95 | `1cc32806` | `style(docs): apply Markdown formatting`          | Skipped: Abird product plan, queue, event, or operational-history document.                                                               |
|  96 | `49e75542` | `fix(flake): dedupe Nixbot module import`         | Adapted: removed only Pvl's duplicate direct Nixbot module import; retained the direct host-agent import required by physical Pvl hosts.  |
|  97 | `b8dc2a66` | `docs(plans): define phase 2C`                    | Skipped: Abird product plan, queue, event, or operational-history document.                                                               |
|  98 | `6b5bd5e2` | `fix(ssh): forward nixbot agent safely`           | Cleanly ported shared OpenSSH module/tests; adapted common-host use to allow agent forwarding only for `nixbot`.                          |
|  99 | `f8247dcf` | `fix(host-control): verify live transfers`        | Cleanly ported byte-for-byte: live-copy drift classification, strict final verification, retry rules, and evidence-driven fallback.       |
| 100 | `491ebf5a` | `docs(migration): record transfer recovery`       | Source migration evidence skipped; transfer verification and recovery rules summarized locally.                                           |
| 101 | `78506e3a` | `style(docs): apply Markdown formatting`          | Skipped with Abird migration plans/events it formats.                                                                                     |
| 102 | `f41e017e` | `fix(tests): remove unused Nix binding`           | Cleanly ported with the OpenSSH test unit.                                                                                                |
| 103 | `b35dc3aa` | `fix(host-agent): own transfer tools`             | Cleanly ported byte-for-byte: the configured host-agent closure owns receiver `rsync` and `tar`.                                          |
| 104 | `716cd60e` | `docs(migration): record receiver tool fix`       | Source event skipped; receiver-tool ownership summarized locally.                                                                         |
| 105 | `093f2e37` | `docs(plans): claim phase 2C`                     | Skipped: Abird product plan, queue, event, or operational-history document.                                                               |
| 106 | `32dea961` | `docs(plans): add prompted task plan`             | Skipped: Abird product plan, queue, event, or operational-history document.                                                               |
| 107 | `1f793402` | `docs(plans): pause 2C and claim PCT`             | Skipped: Abird product plan, queue, event, or operational-history document.                                                               |
| 108 | `14f84f8c` | `feat(agent): retain task objectives`             | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
| 109 | `be8d1128` | `docs(migration): record Zulip verification`      | Skipped: Abird product plan, queue, event, or operational-history document.                                                               |
| 110 | `2cdd5315` | `feat(zulip): select dedicated host`              | Skipped: Abird Zulip placement topology, later reverted by `fe26fdc4`.                                                                    |
| 111 | `a4a2b03b` | `feat(agent): execute prompted diagnostics`       | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
| 112 | `82be07a5` | `feat(agent): secure prompted admission`          | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
| 113 | `c266055d` | `feat(web): add contained task prompt`            | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
| 114 | `381f92c1` | `test(app): prove prompted desktop task`          | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
| 115 | `4c559efa` | `chore(agent): verify prompted task`              | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
| 116 | `bc3998e0` | `docs(agent): close prompted task`                | Skipped: Abird product plan, queue, event, or operational-history document.                                                               |
| 117 | `d0ae5821` | `style(agent): format PCT records`                | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
| 118 | `e2b76716` | `fix(nix): make agent module standalone`          | Skipped: source-owned product, topology, or history with no reusable Pvl unit.                                                            |
| 119 | `32635db1` | `feat(agentic): configure Gondor demo`            | Skipped: Abird/Gondor/Zulip host, stack, demo, or migration topology.                                                                     |
| 120 | `8b37c1c3` | `style(docs): format Gondor note`                 | Skipped: Abird product plan, queue, event, or operational-history document.                                                               |
| 121 | `7da50a02` | `fix(nixbot): include awk at runtime`             | Cleanly ported byte-for-byte: add `gawk` to the Nixbot runtime closure.                                                                   |
| 122 | `318840f0` | `Merge remote-tracking branch 'origin/master'`    | Skipped merge container: no unique portable change beyond individually classified commits.                                                |
| 123 | `e33324c6` | `style(docs): format Zulip events`                | Skipped: Abird product plan, queue, event, or operational-history document.                                                               |
| 124 | `fbbd98b1` | `docs(agent): reconcile and reclaim phase 2c`     | Skipped: Abird product plan, queue, event, or operational-history document.                                                               |
| 125 | `af833e84` | `feat(web): check provider after login`           | Skipped: Abird application agent/web/app/protocol code, product-only checks, or its execution history; no Pvl consumer.                   |
| 126 | `1b423b7f` | `style(docs): fix provider note format`           | Skipped: Abird product plan, queue, event, or operational-history document.                                                               |
| 127 | `fe26fdc4` | `revert(zulip): restore Corp placement`           | Skipped: restores Abird Corp placement; net topology-only with `2cdd5315`.                                                                |
| 128 | `49bcc778` | `docs(migration): record rollback blocker`        | Skipped: Abird product plan, queue, event, or operational-history document.                                                               |
| 129 | `7b925b0a` | `fix(nixbot): scope repository SSH auth`          | Cleanly ported byte-for-byte: per-repository Nixbot SSH identities and host-agent deployment propagation.                                 |
| 130 | `fd3f9cda` | `fix(nixbot): add read-only Abird repo key`       | Skipped: Abird-specific credential deployment and migration history; the reusable repository-scoped identity support was already ported.  |

## Logical port units

1. Hold-aware cold-target deployment: candidate image preparation defers for
   not-yet-created owners, and deploy health excludes stopped durable holds
   while failing closed on malformed hold state.
2. Native host-control operations: hold-checked data wipe, symmetric log modes,
   deferred-job wakeups, broker endpoint pins, OpenSSH host-key derivation, move
   progress, atomic fixture publication, and safe pre-prepare reinvocation.
3. Verified transfer recovery: source drift is distinct from destination damage,
   final copies require independent integrity evidence, retry is limited to
   transient rsync results, and receiver tools come from the configured agent
   closure.
4. Repository-scoped deployment authentication: Nixbot identities belong to a
   repository, propagate into durable deployment policy, and reconcile the
   managed origin without ambient SSH authority.
5. SSH and flake integration: agent forwarding remains denied globally except
   for the explicit `nixbot` user; package module discovery retains unavailable
   platform modules; duplicate Nixbot root import is removed while Pvl retains
   its physical-host agent import.
6. Documentation and parity closeout without importing Abird application,
   Zulip/Gondor topology, migration state, agentic plans, or encrypted secrets.

## Parity contract

At source tip `fd3f9cda`, 350 of 369 common paths under `lib/**` and `pkgs/**`
are byte-identical. Of the 39 source-window paths that exist in both
repositories, 34 are exact and five are intentional adaptations or product
catalog tests:

- `lib/flake/default.nix`: only the reusable unfiltered module-export hunk;
- `lib/flake/root.nix`: Pvl profiles/inputs plus direct physical-host agent
  ownership, Nixbot deduplication, and configuration revision;
- `lib/flake/tests/default.nix` and `pkgs/manifest.nix`: Pvl catalog rather than
  Abird application packages/checks; and
- `pkgs/tools/abird-host-manager/src/main.rs`: logical service lookup defaults
  to `pvl`, not `abird`.

The remaining 14 common differences predate this window: repository-owned
hardware, images, installer, kernel, locale, Nix, stack, sudo, systemd, package
and NATS inventories/documentation, plus the manager's generated Pvl common
module mapping.

Source-window paths absent from Pvl are Abird application/protocol packages,
agentic checks, Zulip/Gondor topology, and product-only support. They are not
shared units merely because they occur under `lib/**` or `pkgs/**`.

## Validation

- Passed 211 native Rust tests: 105 host-agent, 85 manager-library, and 21
  manager-CLI tests.
- Passed 188 Nixbot and 164 Podman Compose Python tests plus shell syntax
  checks.
- Built the native packages, Nixbot, host-agent module/transfer, OpenSSH, flake,
  and all affected Podman Compose checks through Nix.
- Passed the repository lint suite for every supported system, including root
  output indexes and all seven changed NixOS host evaluations.
- Evaluated representative physical `pvl-x2` and Incus `pvl-vlab` systems with
  the host agent enabled; `pvl-x2` emits the intended per-user SSH forwarding
  policy.
- Verified exact cumulative shared-file parity and the five documented
  source-window differences.
