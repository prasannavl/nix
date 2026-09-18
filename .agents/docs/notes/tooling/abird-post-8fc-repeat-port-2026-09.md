# Abird post-`8fc966f8` repeat port, 2026-09-18

## Authority and frozen boundaries

Complete commit-by-commit audit and shared port, directly in the primary main
worktree (same user-authorized override as the prior repeat port). Target
started clean on master at `59c771343e58ff1403b78de2a0bab6f5d488e21e`, in sync
with origin/master. Configured Abird remote frozen master advanced from the
prior anchor `8fc966f85ead2804983062a01f330f584596631d` to
`1b64de2437f73fe3d7463d349ef8d0da400ef397` (77 commits, 71 non-merge; the six
memory-plan commits through published `95282f5a` were already classified as
skipped by the prior audit and are not re-counted here). Only frozen Git objects
were read for source implementations. `data/secrets/*.key.age` in `8eaa93a4` was
never read. No commit, push or deployment was performed.

## Logical units ported (all changes unstaged/untracked in main)

1. Kanidm release pairing (`ffce8f04`): new `pkgs/ext/kanidm-server/cli.nix` and
   paired `cli` releases plus a `kanidm-gap3` 1.11.2 entry in
   `pkgs/ext/kanidm-server/sources.nix`; both files byte/mode exact.
2. Kanidm owned-state verification (`3e605661`): `default.nix`, `helper.sh` and
   `tests/test_helper.py` byte/mode exact (authenticate and verify owned state
   before skipping; failed/malformed reads are probe failures; builtin-account
   pruning protection; changed-attribute-only service-account PUTs; nodejs URL
   canonicalization; 35 passing helper tests). `tests/default.nix` adapted by
   dropping the two gap3-rivendell fixture lines (no such host here).
   `tests/README.md` hunk applied then adapted: Gap3-client claim removed and
   the Abird-only repair-note link dropped; the Pvl upstream-guide divergence
   block at the bottom is retained untouched.
3. Kanidm v1 proof routes (`20b871a6`, kanidm hunks only):
   `tests/authority_proof.py` and `tests/browser_proof.cjs` byte/mode exact
   (`/api/abird.v1alpha1/login/callback` -> `/v1/login/callback`). The rest of
   that commit is Abird product code (abird-agent/abird-web/abird-app).
4. Postgres extension migrations (`8e9d49d2`): new shared
   `lib/services/postgres-extensions/` unit (default.nix, release.json,
   runner.py, tests/test_runner.py) byte/mode exact and fully host-agnostic; 16
   runner tests pass. The pinned image
   `timescale/timescaledb-ha:pg18.6-ts2.30.0` matches the image already used by
   `hosts/pvl-x2/services/postgres.nix`. No registration is needed in either
   repo; hosts import the unit directly. Host consumers (`54f7c845`, `91688c51`,
   `c81ea7e1`) are Abird/gap3 hosts and are skipped; adopting
   `release.image`/`mkRunner` in pvl-x2 is future work.
5. Graphiti 0.30.2 core contract (`71602834`): all seven
   `pkgs/support/zep-graphiti/` files byte/mode exact (duplicate-candidate and
   retry-field contract fixes, `_handle_structured_response` delegation,
   `RefusalError` handling, `release.json` passthru, and the standalone offline
   `tests/` suite). The package check build passes, which runs the packaged
   unittest discovery. Host deploy `35746492` is skipped (no host consumer here
   yet).
6. Placement-aware client access (`8acece33` + `7037a12e` shared parts): the
   52-line `lib/flake/service-registry.nix` helper block (`servicesShareHost`,
   `allowedClientsFor`, `clientEndpointForService`, `allowedClientIpv4CidrsFor`)
   is byte-exact with source. New generic
   `.agents/docs/design-patterns/service-client-access.md` adapted (Abird
   Stalwart consumer sentence dropped, code-span linebreak fixed). New
   `lib/flake/tests/service-client-endpoints.nix` keeps the synthetic half of
   the source test (16 asserts, builds green as
   `lib-flake-service-client-endpoints`); the Abird-bound integration half (real
   abird stacks, corp hosts, subnets, SMTP env keys) is skipped.
   `tests/default.nix` registration added. The `phase-projection.nix` +8 hunk is
   skipped: it asserts real Abird stack projection; equivalent coverage of the
   new helpers under colocated/different-address/different-project/cold
   placement lives in the synthetic endpoints test.
   `lib/stacks/abird-registry.nix` and all `hosts/abird-*` consumers are
   source-only.
7. Updater GitHub token bridge (`1d4acd0a`): `scripts/update.sh`,
   `scripts/support/podman-image-updater.py`,
   `scripts/support/tests/test_podman_image_updater.py`,
   `scripts/support/tests/test_update_source_discovery.py` and
   `pkgs/tools/nixbot/nixbot.sh` byte-exact to the source commit
   (`configure_github_nix_access_token` appending
   `extra-access-tokens = github.com=<token>` to `NIX_CONFIG`, GITHUB_TOKEN
   passed to api.github.com release queries, GH_TOKEN fallback, test-env token
   hygiene). `pkgs/tools/nixbot/tests/test_nixbot.py` patched with the two new
   tests while retaining the Pvl seven-host ordering test. `README.md` gained
   the GitHub API Authentication section with Pvl prose retained. Fully generic
   for any GitHub-hosted flake input.
8. VS Code extensions lock (`64c2fca8`): `vscode-ext` locked node advanced to
   rev `71d01d8255807d1d0c2ed2b92875aa0fdfad8654`,
   `sha256-4+A+2fDVxHC83CAh6gJAX6A0whCcaO4wdOxwjXvCvd8=`, lastModified
   `1789532447`; the node now equals `abird/master` exactly. No other lock nodes
   changed.

## Every source commit in `8fc966f8..abird/master`

Status legend: ported = applied as committed (byte/mode exact shared files);
adapted = ported with Pvl-specific changes; skipped = nothing ported.

| #  | Commit     | Subject                                                | Status  | Notes                                                                                                                                       |
| -- | ---------- | ------------------------------------------------------ | ------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| 1  | `0918cd99` | docs(plan): define memory requirement coverage         | skipped | Abird memory-product planning; docs-only.                                                                                                   |
| 2  | `aba7b11d` | docs(plan): define no-memory work policy               | skipped | Abird memory-product policy; docs-only.                                                                                                     |
| 3  | `305c3e56` | docs(plan): define memory lifecycle                    | skipped | Abird controller memory lifecycle design; docs-only.                                                                                        |
| 4  | `7568d1ef` | docs(plan): define deletion-safe memory replay         | skipped | Abird memory replay semantics; docs-only.                                                                                                   |
| 5  | `64e32252` | docs(plan): define encrypted memory backups            | skipped | Abird memory backup plan; docs-only.                                                                                                        |
| 6  | `95282f5a` | docs(plan): require fresh repository memory            | skipped | Abird repository-memory freshness plan; docs-only.                                                                                          |
| 7  | `1d4acd0a` | fix(update): bridge GitHub token to Nix                | adapted | Five shared files byte-exact; test_nixbot.py patched to keep Pvl ordering test; README adapted.                                             |
| 8  | `4297b48d` | Merge remote-tracking branch 'origin/master'           | skipped | Clean merge, no unique content.                                                                                                             |
| 9  | `9727dc75` | docs(plan): bind memory to provider operations         | skipped | Abird memory plan; docs-only.                                                                                                               |
| 10 | `4b282066` | chore(nats): update Abird server and exporter          | skipped | hosts/abird-data only.                                                                                                                      |
| 11 | `b6af36d2` | chore(observability): update Abird telemetry           | skipped | hosts/abird-obs only.                                                                                                                       |
| 12 | `0c8138c8` | chore(ollama): update Abird ROCm runtime               | skipped | hosts/abird-srv only.                                                                                                                       |
| 13 | `26b42794` | chore(auth): update oauth2-proxy to 7.15.4             | skipped | hosts/abird-proxy only.                                                                                                                     |
| 14 | `ec6d0cbf` | chore(forgejo): update Abird to v16                    | skipped | hosts/abird-corp only.                                                                                                                      |
| 15 | `f628ab34` | chore(mattermost): update Abird to 11.11               | skipped | hosts/abird-corp only.                                                                                                                      |
| 16 | `24da4375` | chore(excalidash): update Abird to 0.6                 | skipped | hosts/abird-corp only.                                                                                                                      |
| 17 | `82339167` | docs(plan): govern memory proposal extraction          | skipped | Abird memory plan; docs-only.                                                                                                               |
| 18 | `4ab58cd0` | docs(nixbot): clarify failed-service visibility        | skipped | Abird .agents note only.                                                                                                                    |
| 19 | `64c2fca8` | chore(inputs): refresh VS Code extensions              | adapted | vscode-ext locked node updated to equal source; rest of lock untouched.                                                                     |
| 20 | `6844b9fb` | docs(agents): resolve GitHub actor attribution         | skipped | Abird .agents docs only.                                                                                                                    |
| 21 | `63c5794b` | fix(hermes): restore native Kanidm auth                | skipped | Abird hosts + Abird-scoped note.                                                                                                            |
| 22 | `de66247a` | fix(librechat): enable persisted index upgrade         | skipped | hosts/abird-corp + Abird note.                                                                                                              |
| 23 | `c866888a` | test(auth): guard Corp recovery contracts              | skipped | `abird-corp-auth.nix` imports real Abird stacks/hosts; Abird-bound.                                                                         |
| 24 | `e5ddb380` | chore(gap3): update validated runtime services         | skipped | hosts/gap3-rivendell only.                                                                                                                  |
| 25 | `85eb4d83` | Merge remote-tracking branch 'origin/master' into HEAD | skipped | Clean merge, no unique content.                                                                                                             |
| 26 | `83fdd4e5` | style(docs): format deployment acceptance              | skipped | Abird .agents formatting only.                                                                                                              |
| 27 | `4c8bb158` | docs(plan): define first-release memory protocol       | skipped | Abird memory plan; docs-only.                                                                                                               |
| 28 | `4aa6b090` | chore: merge latest master                             | skipped | Clean merge, no unique content.                                                                                                             |
| 29 | `7f465c13` | chore(anythingllm): update to 1.16.1                   | skipped | hosts/abird-corp only.                                                                                                                      |
| 30 | `62ba751e` | chore(superset): update Redis to v8                    | skipped | hosts/abird-corp only.                                                                                                                      |
| 31 | `67441a2a` | chore(grafana): update both hosts to 13.2.2            | skipped | Abird hosts only.                                                                                                                           |
| 32 | `f0912079` | chore(victorialogs): update both hosts to 1.52         | skipped | Abird hosts only.                                                                                                                           |
| 33 | `3cfc0c71` | chore(hatchet): update PostgreSQL to 15.19             | skipped | hosts/gap3-rivendell only.                                                                                                                  |
| 34 | `010dc8c4` | chore(zulip): update Gap3 to 12.2                      | skipped | hosts/gap3-rivendell only.                                                                                                                  |
| 35 | `47cde7bf` | docs(updates): record phase-two acceptance             | skipped | Abird .agents note only.                                                                                                                    |
| 36 | `314daeba` | Merge remote-tracking branch 'origin/master' into HEAD | skipped | Clean merge, no unique content.                                                                                                             |
| 37 | `716cd9f2` | docs(plan): clarify memory delivery stages             | skipped | Abird memory plan; docs-only.                                                                                                               |
| 38 | `8acece33` | refactor(registry): derive client access by placement  | ported  | 52-line generic helper block byte-exact in lib/flake/service-registry.nix.                                                                  |
| 39 | `7037a12e` | fix(abird): derive SMTP access from placement          | adapted | Registry block (via 8acece33) + design doc + synthetic endpoints test + registration; Abird hosts/stacks and integration-test half skipped. |
| 40 | `7cbb9eca` | chore(zulip): update server and memcached              | skipped | hosts/abird-corp only.                                                                                                                      |
| 41 | `67a5265d` | chore(vllm): update disabled ROCm image                | skipped | hosts/abird-srv only.                                                                                                                       |
| 42 | `c3710a80` | chore(stalwart): update Gap3 scaffold image            | skipped | hosts/gap3-rivendell only.                                                                                                                  |
| 43 | `f2edef3a` | docs: record staged deployment acceptance              | skipped | Abird .agents records only.                                                                                                                 |
| 44 | `d2b18471` | Merge remote-tracking branch 'origin/master'           | skipped | Clean merge, no unique content.                                                                                                             |
| 45 | `579b3af4` | docs(plan): accept 3.7a API cutover                    | skipped | Abird plan acceptance; docs-only.                                                                                                           |
| 46 | `1b23c9af` | chore(n8n): select stable 2.39.6                       | skipped | Abird hosts only.                                                                                                                           |
| 47 | `848aff7d` | chore(outline): update app and Redis                   | skipped | Abird hosts only.                                                                                                                           |
| 48 | `27d2898e` | chore(odoo): update empty scaffold to 19               | skipped | hosts/abird-corp only.                                                                                                                      |
| 49 | `cae70f3b` | fix(strapi): build admin UI during upgrade             | skipped | hosts/abird-corp only.                                                                                                                      |
| 50 | `d8b16f59` | fix(penpot): align images and asset storage            | skipped | hosts/abird-corp only.                                                                                                                      |
| 51 | `4eda350e` | fix(novu): align release and protocol routes           | skipped | Abird hosts only.                                                                                                                           |
| 52 | `bb3ac760` | docs: record upgrade validation and contracts          | skipped | Abird .agents records only.                                                                                                                 |
| 53 | `23ef2a5b` | chore(zulip): upgrade Abird broker and Redis           | skipped | hosts/abird-corp only.                                                                                                                      |
| 54 | `9d41fe35` | chore(opencloud): select production 7.2.4              | skipped | hosts/abird-corp only.                                                                                                                      |
| 55 | `194d2dcf` | docs: record Zulip and OpenCloud acceptance            | skipped | Abird .agents records only.                                                                                                                 |
| 56 | `b5af7e88` | chore: merge upstream API cutover plan                 | skipped | Clean merge, no unique content.                                                                                                             |
| 57 | `3f7b6472` | chore(metabase): apply security bridge                 | skipped | hosts/abird-corp only.                                                                                                                      |
| 58 | `3f48b92e` | chore(garage): upgrade to 1.3.1                        | skipped | hosts/gap3-rivendell only.                                                                                                                  |
| 59 | `91688c51` | chore(abird): update shared Postgres image             | skipped | hosts/abird-data only.                                                                                                                      |
| 60 | `c81ea7e1` | chore(gap3): update shared Postgres image              | skipped | hosts/gap3-rivendell only.                                                                                                                  |
| 61 | `8378de01` | chore(zulip): upgrade Gap3 broker and Redis            | skipped | hosts/gap3-rivendell only.                                                                                                                  |
| 62 | `c0ae02ae` | docs(updates): record deployment acceptance            | skipped | Abird .agents records only.                                                                                                                 |
| 63 | `101e6f45` | docs(reconcile): record upgrade contract gaps          | skipped | Abird .agents records only.                                                                                                                 |
| 64 | `ffce8f04` | build(kanidm): pair server and CLI releases            | ported  | cli.nix + sources.nix byte/mode exact.                                                                                                      |
| 65 | `fd22e619` | fix(gap3): update the Kanidm release contract          | skipped | hosts/gap3-rivendell only (consumer of unit 64).                                                                                            |
| 66 | `8eaa93a4` | fix(abird-id): restore Kanidm admin access             | skipped | hosts/abird-id + encrypted secret (never read).                                                                                             |
| 67 | `3e605661` | fix(kanidm): verify owned state before skipping        | adapted | Three shared files byte-exact; tests/default.nix minus gap3 fixture; README adapted.                                                        |
| 68 | `8e9d49d2` | feat(postgres): add explicit extension migrations      | ported  | New shared lib/services/postgres-extensions unit, all four files byte/mode exact.                                                           |
| 69 | `54f7c845` | feat(hosts): expose PostgreSQL migration commands      | skipped | Abird/gap3 host consumers only.                                                                                                             |
| 70 | `71602834` | fix(graphiti): support the 0.30.2 core contract        | ported  | All seven pkgs/support/zep-graphiti files byte/mode exact.                                                                                  |
| 71 | `35746492` | chore(abird-data): update Graphiti to 0.30.2           | skipped | hosts/abird-data deploy only.                                                                                                               |
| 72 | `283231ae` | docs(updates): record repairs and publication gates    | skipped | Abird .agents records only.                                                                                                                 |
| 73 | `180b7a71` | docs(updates): record deployed acceptance              | skipped | Abird .agents records only.                                                                                                                 |
| 74 | `20b871a6` | feat(agent)!: cut API over to v1                       | adapted | Only the two kanidm proof-fixture route renames ported (byte-exact); abird-agent/web/app product code skipped.                              |
| 75 | `5dcad650` | docs(agent): record 3.7a deployment                    | skipped | Abird .agents records only.                                                                                                                 |
| 76 | `5815d65c` | test(agent): allow loaded resume check                 | skipped | pkgs/srv/abird-agent only; Abird product code not present here.                                                                             |
| 77 | `1b64de24` | docs(agent): close 3.7a and accept 3.7b                | skipped | Abird .agents records only.                                                                                                                 |

## Validation

- All support suites pass: 58 scripts/support tests, 16 postgres-extension
  runner tests, 272 nixbot tests, 35 kanidm helper tests.
- Nix checks build green: `lib-kanidm-normalization`, `lib-kanidm-helper`,
  `lib-flake-service-client-endpoints`, packaged `lib-podman-image-updater`, and
  the zep-graphiti package check (unittest discovery).
- Diff lint over the ported files passes: alejandra, statix, deadnix, shfmt,
  shellcheck, actionlint, tflint, deno fmt, markdownlint-cli2. The explicit
  `--base HEAD` diff lint compares committed refs only and skips uncommitted
  files (same documented caveat as the prior audit), so per-file lints were run
  directly over the changed file set and the root-flake/index/host evaluation
  ran through the lint suite.
- flake.lock is valid JSON and the vscode-ext node equals source exactly.

## Byte/mode parity

Live common lib/pkgs/scripts paths: 519. Exact bytes and modes: 493. Explained
common content differences: 26 (the 24 documented repository-policy divergences
from the prior audit plus two new intentional adaptations:
`lib/services/kanidm/tests/default.nix` gap3-fixture drop and
`lib/flake/tests/service-client-endpoints.nix` synthetic-only test; the kanidm
tests/README.md divergence remains the previously documented one). Mode
differences: 0. Source-only paths: 294 (all Abird product/stack/lab trees).
Pvl-only paths: 40 (unchanged Pvl desktop/hardware/profile/stack set). Exact-set
SHA256 over sorted path/mode/blob lines without trailing newline:
`3f771f8df54abff20eb8c23feeafda6fde614561d54d06f9af79715cf4da013d`.

Source added exactly 11 lib/pkgs/scripts paths since the prior anchor; 10 are
now common-exact and only `lib/flake/tests/abird-corp-auth.nix` is intentionally
absent (imports real Abird stacks and corp hosts).

No unexplained relevant shared gap remains in the frozen configured source
branch. Future work noted: adopt `postgres-extensions.release.image`/`mkRunner`
in `hosts/pvl-x2/services/postgres.nix` when desired.
