# gap3 Last-50 Port Ledger, 2026-06

## Scope

Selective port of the refreshed last 50 commits on `gap3/master` as of
2026-06-01, first ending at `254bdf52 docs(incus): format vm support note`, then
refreshed through `4f11011c fix(git): reject dirty pre-push lint`.

The next refresh on 2026-06-06 reviewed `4f11011c..086549c3`, ending at
`086549c3 feat(incus): add managed fabric policies`.

The 2026-06-07 refresh reviewed gap3 `9a8de8de..99a9d640` from `origin/master`
plus local gap3 `11f905d3`, which was ahead of origin in the gap3 checkout.

The 2026-06-08 refresh reviewed gap3 `11f905d3..6aa0246c`, with the explicit
last-10 commit set from `020d2bcf..6aa0246c`.

The 2026-06-10 refresh reviewed the current `abird/master` last 50 ending at
`2f7eee54 fix(abird): restore nest tailnet ssh`.

Do not cherry-pick the range wholesale. Port shared library/package machinery
byte-for-byte where this repo has no intentional divergence; adapt only local
repo surfaces such as package manifests, image aliases, and docs.

Do not read `.key` files under `data/secrets`. Listing secret paths is allowed
only when classifying commits.

## Port Units

1. Nginx and Podman stream proxy machinery: `c50e3747`, `83506a27`, `5cc0f6b2`,
   `eeff0e1b`, `05e530f5`.
2. ActiveSync, Z-Push, AWL, and shared Stalwart patches: `057bf178`, `2b3c5fec`,
   `e1a790a1`, `a510618b`, `21e5bf18`, `5880af73`, `79725118`, `ebc8ac98`,
   `22a3b43a`, `b3d97481`, `a363cc38`, `74cfd4a5`.
3. Incus VM-kind support: `72df49cd`, `254bdf52`.
4. Nixbot and Rust package-helper utilities: `e224a6d1`, generic
   `lib/flake/pkg-helper.nix` portion of `5df298e2`.
5. Nixbot refresh and git hook hygiene: `53fdad50`, `5cc7dac1`, `4f11011c`.
6. Mail package refresh: `d5c87b96`, `8d11ef18`, `c483953c`, `441f7dc6`,
   `a88c2308`, `49875633`, `cc7ae3ba`, `d8f1eb96`, `37ef6e1b`, `7f6198d8`,
   `7e9e3604`, `809b532a`, `51975d34`, `2079c695`, `82102560`, `9ba95f6e`,
   `0f58144f`, `e7f3303e`, `b939bdfa`, `acd1c294`.
7. Lifecycle and verification helpers: `b552af06`, `933ead20`, `fc7a95e9`,
   `04e618c9`, `74ced4e3`, `24de1c0a`, `0da83f1e`, `e866ac32`, `b8f83778`,
   `a89ea9b3`, `9408d292`, `fa08daf4`, `8009c5e8`, `086549c3`.
8. Nix, lint, and deployment tooling: `7d37017a`, `10019c2c`, `2a797daf`,
   `a571fcea`, `90ab7901`, `3cf9366e`, `b00101b1`, `0b2e6108`, `c3e982ec`,
   `30ccd900`, `4acb4186`, `a1334c8f`, `ee0bf55f`, `5d991a24`, `e774e74c`.
9. GCP VM helper HTTPS firewall support from `b8a008e3`.

## Current Decisions

- Ported shared files from `gap3/master` byte-for-byte for:
  `lib/podman-compose/default.nix`, `lib/services/nginx/default.nix`,
  `lib/services/nginx/ingress-composer.nix`,
  `lib/services/tunnels/cloudflare.nix`, `lib/services/activesync/**`,
  `lib/services/stalwart/default.nix`, `lib/services/stalwart/helper.sh`,
  `lib/incus/default.nix`, `lib/incus/helper.sh`, `lib/flake/pkg-helper.nix`,
  `pkgs/ext/awl/**`, `pkgs/ext/z-push/**`, `pkgs/ext/stalwart-server/**`, and
  `pkgs/tools/nixbot/nixbot.sh`.
- Ported `.githooks/pre-push` byte-for-byte from `gap3/master` so local pre-push
  lint rejects dirty worktrees before running lint.
- Adapted `lib/images/default.nix` instead of copying upstream byte-for-byte:
  upstream introduces `incus-lxc-base` and `incus-vm-base`; this repo still has
  local callers using `incus-base` and `gap3-base`, so `incus-base` remains a
  compatibility alias and `gap3-base` keeps its existing local `stacks.pvl`
  image.
- Adapted `pkgs/manifest.nix` to expose `awl` without importing unrelated
  upstream package entries.
- Adapted `README.md` to document the Incus image split and
  `nixbot --list-hosts` / `result-dev/<host>` behavior without importing
  unrelated upstream README drift.
- Adapted local `.agents/docs/notes/nixbot/deploy-system.md` with the upstream
  `dev-build` result directory semantics. Skipped importing gap3's consolidated
  nixbot operations note because this repo keeps that content split into local
  note files.
- Keep Abird/GAP3 host services, DNS, route usage, and secret wiring skipped
  unless a matching local service stack is explicitly requested.
- For the 2026-06-06 refresh, kept this repo's `data/secrets/pvl/services`
  service default and existing Terraform/CI secret paths instead of adopting
  gap3's `data/secrets/globals` and `data/secrets/gap3/services` migration.
- Kept local flake inputs and overlays, including desktop overlays. Ported
  `crane` support by adding the input and overlay without copying gap3's smaller
  top-level `flake.nix`.
- Kept local `lib/flake/stack.nix` compatibility import even though gap3 removed
  it.
- Ported portable Nixbot behavior changes but not gap3-specific secret path
  defaults.

## Commit Disposition

| Commit     | Subject                                               | Disposition                                                                                           |
| ---------- | ----------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| `f0b4b793` | fix(abird): expose mail client discovery              | Skip host-specific Abird mail/proxy/DNS usage; shared GCP firewall helper was already ported earlier. |
| `c50e3747` | feat(nginx): support proxy buffering overrides        | Ported shared nginx helper state through byte-compatible nginx files.                                 |
| `6fe820b5` | feat(stalwart): tune jmap push streaming              | Skip Abird route/config usage.                                                                        |
| `9b598c15` | refactor(abird): name long proxy timeouts             | Skip Abird stack constants.                                                                           |
| `b05fe928` | docs(abird): clarify ollama streaming timeouts        | Skip Abird docs.                                                                                      |
| `e5dac1c8` | feat: serve new pkg and host                          | Skip Abird tictactoe host/app package.                                                                |
| `7610fb00` | Route nixbot gondor deploys through Cloudflare Access | Skip host-specific nixbot routing.                                                                    |
| `f07d884c` | fix: handle touch input for tictactoe                 | Skip tictactoe app.                                                                                   |
| `83506a27` | refactor(abird-proxy): compose nginx ingress          | Ported shared ingress composer/unit helpers; skipped Abird route usage.                               |
| `d577ee49` | feat(abird-corp): add ActiveSync bridge               | Ported base `z-push` package only where shared; skipped Abird host bridge.                            |
| `098832f9` | fix(stalwart): use numeric jmap durations             | Skip Abird Stalwart config usage.                                                                     |
| `76056ab6` | fix(activesync): move z-push state dir                | Skip Abird host usage; shared ActiveSync service is ported by later commits.                          |
| `216ba958` | feat(stalwart): publish submission STARTTLS           | Already represented or host-specific; no new shared port.                                             |
| `275dd17b` | feat(stalwart): publish IMAP STARTTLS                 | Already represented for shared Stalwart patch; host usage skipped.                                    |
| `4f38754a` | feat(nginx): add upstream CA cert support             | Already represented in shared nginx files.                                                            |
| `ca54ccad` | abird: centralize ai model config                     | Skip Abird service config.                                                                            |
| `541113a1` | abird: add manual openai backends                     | Skip Abird service config.                                                                            |
| `4ea6509b` | fix(stalwart): trust app smtp relays                  | Skip Abird app relay config.                                                                          |
| `5559a030` | fix(stalwart): remove proxied discovery srv           | Skip Abird DNS/config.                                                                                |
| `84a8b584` | fix(stalwart): authenticate z-push protocols          | Skip Abird host config.                                                                               |
| `057bf178` | feat(z-push): package AWL for DAV sync                | Ported shared `awl` package and Z-Push CalDAV patch.                                                  |
| `2b3c5fec` | feat(activesync): add reusable Z-Push service         | Ported shared `lib/services/activesync`.                                                              |
| `253df4b9` | feat(abird): serve ActiveSync through host nginx      | Skip Abird host/proxy usage.                                                                          |
| `e1a790a1` | fix(stalwart): normalize calendar mailto recipients   | Ported shared Stalwart patch.                                                                         |
| `27f69e5e` | docs(abird): record ActiveSync rollout notes          | Skip Abird docs.                                                                                      |
| `a510618b` | activesync: set AWL on PHP include path               | Ported in shared ActiveSync service.                                                                  |
| `21e5bf18` | activesync: leave calendar writes to DAV              | Ported in shared ActiveSync PHP config.                                                               |
| `5cc0f6b2` | feat(nginx): add route proxy primitives               | Ported shared route/upstream machinery.                                                               |
| `07e45a52` | opencloud: allow creating Draw files                  | Skip Abird OpenCloud service config.                                                                  |
| `5880af73` | fix(activesync): scope nginx origin vhost             | Ported reusable ActiveSync service portion; skipped Abird route usage.                                |
| `e384d4e7` | Merge remote-tracking branch 'origin/master'          | No direct port; handled by constituent changes.                                                       |
| `4557416e` | style(tictactoe): format UI imports                   | Skip tictactoe app.                                                                                   |
| `79725118` | activesync: use LDAP sender display names             | Ported in shared ActiveSync service.                                                                  |
| `eeff0e1b` | feat(nginx): add stream proxy helpers                 | Ported shared stream proxy helpers.                                                                   |
| `ad1b685b` | fix(abird): route Kanidm LDAPS via proxy              | Skip Abird route usage; shared stream proxy foundation is ported.                                     |
| `05e530f5` | refactor(nginx): unify stream proxy ports             | Ported shared stream port/tunnel helpers.                                                             |
| `ebc8ac98` | fix(stalwart): repair calendar invites                | Ported shared Stalwart patches and helper reconciliation change.                                      |
| `22a3b43a` | fix(stalwart): run DMARC without SPF                  | Ported shared Stalwart patch.                                                                         |
| `f58c1fcb` | fix(stalwart): whitelist TLS reports                  | Skip Abird Stalwart config.                                                                           |
| `b3d97481` | fix(stalwart): ingest external RSVP replies           | Ported shared Stalwart patch.                                                                         |
| `b32531bc` | docs: format Abird notes                              | Skip Abird docs.                                                                                      |
| `5df298e2` | fix(rust-tictactoe): satisfy clippy checks            | Ported generic `pkg-helper` check-input/env plumbing; skipped tictactoe app changes.                  |
| `72df49cd` | feat(incus): add vm instance kind                     | Ported shared Incus VM-kind machinery; adapted image aliases locally.                                 |
| `a363cc38` | fix(stalwart): drop organizer self-attendees          | Ported shared Stalwart patch.                                                                         |
| `74cfd4a5` | fix(stalwart): prefer attendee in RSVP replies        | Ported shared Stalwart patch update.                                                                  |
| `265ab453` | fix(abird): set calendar RSVP endpoint                | Skip Abird Stalwart/Bulwarkmail config.                                                               |
| `e224a6d1` | feat(nixbot): list selected hosts                     | Ported shared nixbot CLI feature.                                                                     |
| `8e003a0a` | fix(ollama): avoid deploy cold-starts                 | Already represented locally for `pvl-a1`; gap3 host usage skipped.                                    |
| `4a7cbf9d` | fix(abird): rotate mta-sts policy                     | Skip Abird DNS/policy config.                                                                         |
| `254bdf52` | docs(incus): format vm support note                   | Ported Incus VM support docs into `docs/incus-vms.md`.                                                |
| `53fdad50` | fix(nixbot): keep per-host result links               | Ported shared nixbot script byte-for-byte.                                                            |
| `5cc7dac1` | fix(nixbot): group dev-build result links             | Ported shared nixbot script and adapted local README/nixbot note to `result-dev/<host>`.              |
| `4f11011c` | fix(git): reject dirty pre-push lint                  | Ported shared pre-push hook byte-for-byte and adapted README wording only.                            |

## 2026-06-06 Refresh Disposition

| Commit     | Subject                                                                 | Disposition                                                                        |
| ---------- | ----------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| `d5c87b96` | rust: split cargo builds with crane                                     | Ported `pkg-helper` crane helpers and adapted local flake/overlay wiring.          |
| `b3426894` | fix(stalwart): authenticate smtp calendar replies                       | Skip Abird host config.                                                            |
| `8d11ef18` | stalwart: fixes                                                         | Ported shared Stalwart patch updates; skipped Abird docs/host usage.               |
| `c483953c` | bulwarkmail: use stalwart scheduling                                    | Ported reusable `bulwarkmail` package; skipped Abird service wiring.               |
| `441f7dc6` | fix(bulwarkmail): gate client iMIP sending                              | Ported reusable `bulwarkmail` package patch.                                       |
| `a88c2308` | fix(stalwart): avoid patch drift                                        | Ported shared Stalwart patches.                                                    |
| `49875633` | build(stalwart): bump to 0.16.7                                         | Ported shared Stalwart package bump.                                               |
| `0bcb1be5` | docs(mail): record scheduling ownership                                 | Skip Abird host notes.                                                             |
| `7d37017a` | fix(nixbot): use dash host exclusions                                   | Ported Nixbot selector behavior with local docs.                                   |
| `10019c2c` | docs(nixbot): document dash exclusions                                  | Adapted into local `deploy-system.md`; skipped gap3 doc layout.                    |
| `cc7ae3ba` | build(stalwart): use fixed thin LTO units                               | Ported shared Stalwart package build settings.                                     |
| `267aa7b8` | docs(stalwart): record thin LTO override                                | Skip Abird host note.                                                              |
| `2a797daf` | style(docs): format nixbot docs                                         | Skip gap3-only consolidated docs.                                                  |
| `66600700` | fix(stalwart): add internal smtp listener                               | Skip Abird host/listener wiring.                                                   |
| `d8f1eb96` | fix(z-push): normalize calendar writes                                  | Ported shared ActiveSync and Z-Push patches.                                       |
| `37ef6e1b` | fix(bulwarkmail): defer calendar iMIP                                   | Ported reusable `bulwarkmail` package patch.                                       |
| `7f6198d8` | fix(stalwart): own calendar iTIP                                        | Ported shared Stalwart reply sender patch; skipped host config.                    |
| `7e9e3604` | fix(z-push): use IANA fixed offsets                                     | Ported shared Z-Push timezone patch.                                               |
| `b552af06` | feat(systemd-user-manager): add lifecycle state                         | Already represented locally; resynced shared helper.                               |
| `933ead20` | feat(podman-compose): add lifecycle policies                            | Already represented locally; resynced shared helper.                               |
| `fc7a95e9` | feat(incus): add lifecycle policies                                     | Already represented locally; remaining shared diff skipped or absent.              |
| `04e618c9` | docs: record lifecycle policy redesign                                  | Already represented by local lifecycle docs.                                       |
| `74ced4e3` | fix(podman-compose): declare composectl inputs                          | Ported shared composectl/helper update.                                            |
| `7b23748e` | fix(zulip): suppress shutdown admin noise                               | Skip host-specific Zulip helper.                                                   |
| `b8a008e3` | feat(abird): add JMAP SRV discovery                                     | Ported reusable GCP VM HTTPS firewall helper only; skipped Abird DNS/routes.       |
| `3e06f34b` | fix(bulwarkmail): defer iMIP scheduling                                 | Ported reusable `bulwarkmail` package patch.                                       |
| `809b532a` | fix(z-push): normalize organizer attendees                              | Ported shared Z-Push organizer patch.                                              |
| `51975d34` | fix(stalwart): dedupe organizer snapshots                               | Ported shared Stalwart organizer patch replacement.                                |
| `2079c695` | fix(stalwart): accept calendar reply senders                            | Ported shared Stalwart reply sender patch.                                         |
| `7619f3b6` | docs: record calendar scheduling fixes                                  | Skip Abird host note.                                                              |
| `82102560` | fix(calendar): tighten organizer handling                               | Ported shared Stalwart/Z-Push patch updates.                                       |
| `9ba95f6e` | fix(stalwart): load local image for reconcile                           | Ported reusable Stalwart helper `imageTar` support.                                |
| `0f58144f` | style(stalwart): fix lint formatting                                    | Ported shared Stalwart formatting in copied helper.                                |
| `24de1c0a` | feat(systemd-user): add verify hook                                     | Ported shared systemd-user-manager verify hook.                                    |
| `0da83f1e` | fix(podman): verify applied runtime state                               | Ported shared podman-compose verify hook.                                          |
| `e7f3303e` | fixes(stalwart): bulwarkmail and zpush cal organizer fixes              | Ported reusable package patches.                                                   |
| `b939bdfa` | fix(stalwart): hydrate organizer CN from identity                       | Ported shared Stalwart patch.                                                      |
| `8fcfb0d2` | refactor(secrets): stack-scope secret tree                              | Skip gap3 secret-tree migration; keep local secret paths.                          |
| `a571fcea` | feat(nix): fix cross-system flake outputs and package platform handling | Ported package-platform handling; adapted local flake wiring.                      |
| `a9a122c4` | refactor(abird-tictactoe): isolate test host identity                   | Skip Abird/tictactoe host identity.                                                |
| `e866ac32` | fix(podman): avoid hashing generated ca bundle                          | Ported shared podman CA hash handling.                                             |
| `b8f83778` | fix(podman): avoid reading store secret sources                         | Ported shared podman secret-source hash handling.                                  |
| `90ab7901` | fix(lint): target root checks for prs                                   | Ported shared lint workflow/script behavior.                                       |
| `3cf9366e` | feat: run full flake checks in full lint mode                           | Ported shared lint script behavior.                                                |
| `b00101b1` | refactor(flake): avoid IFD in package availability checks               | Ported package availability filtering.                                             |
| `0b2e6108` | chore(nixbot): use cheap nix eval for host list                         | Ported Nixbot host list eval.                                                      |
| `acd1c294` | fix(activesync): stabilize z-push root                                  | Ported reusable ActiveSync document root support.                                  |
| `c3e982ec` | fix(lint): widen shared host root checks                                | Ported shared lint script behavior.                                                |
| `30ccd900` | refactor(lint): default to current system                               | Ported shared lint script behavior.                                                |
| `a89ea9b3` | fix(podman): declare CA restart inputs                                  | Ported shared podman CA restart input options.                                     |
| `9408d292` | fix(podman-compose): verify scoped staged files                         | Ported shared podman-compose verification.                                         |
| `4acb4186` | fix(nixbot): verify deploys after transport loss                        | Ported Nixbot transport-loss verification without secret path migration.           |
| `fa08daf4` | fix(systemd-user-manager): reject duplicate units                       | Ported shared duplicate managed-unit assertion.                                    |
| `8009c5e8` | fix(systemd-user-manager): harden reconcile state                       | Ported shared request-marker and reconcile hardening.                              |
| `a1334c8f` | fix(lint): format flake and docs                                        | Ported shared flake helper formatting; skipped gap3 doc layout.                    |
| `ee0bf55f` | fix(pkg): gate cloudflare apps deploy to linux                          | Ported package platform metadata.                                                  |
| `5d991a24` | feat(flake): pass overlays through flakeLib package eval                | Ported overlay threading with local flake inputs preserved.                        |
| `e774e74c` | feat(rust): add isolated cargo workspace helper                         | Ported `mkCargoWorkspacePackage`.                                                  |
| `24ae0efa` | fix(incus): abird-nest incus mount interceptions                        | Skip Abird host Incus usage.                                                       |
| `086549c3` | feat(incus): add managed fabric policies                                | Already represented locally by managed fabric commits; no new shared diff to port. |

## 2026-06-07 Refresh Disposition

| Commit     | Subject                                          | Disposition                                                                                                                                                                                                                                     |
| ---------- | ------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `99930feb` | refactor(flake): remove stale collections helper | Already clean locally; no `lib/flake/collections/default.nix` remained to remove.                                                                                                                                                               |
| `19e139f8` | fix(secrets): isolate incus remote data          | Adopted shared `lib/flake/secrets.nix` cleanup; skipped Abird-nest secret paths and host split.                                                                                                                                                 |
| `6b5b1806` | refactor(incus): share mkLxc helper              | Already clean locally; `lib/incus/lib.nix` was byte-identical before this refresh.                                                                                                                                                              |
| `29e880db` | feat: add price indexer (#1)                     | Skipped app and Abird test-host rollout; package is lab/Abird-specific and very large.                                                                                                                                                          |
| `3f0766bc` | refactor(secrets): track service key paths       | Ported shared service-secret path helpers byte-for-byte; host parrot consumers skipped.                                                                                                                                                         |
| `d0295eb9` | chore(gap3): disable parrot bots                 | Skipped gap3 host/service secret removal.                                                                                                                                                                                                       |
| `84daf87e` | feat(abird): enable parrot bots                  | Skipped Abird host services and encrypted secret material.                                                                                                                                                                                      |
| `13abc93d` | fix(parrot): trust native TLS roots              | Skipped bot package dependency change because the bot packages are not local manifest entries.                                                                                                                                                  |
| `b981823e` | fix(zulip-parrot): token email                   | Skipped Abird service config.                                                                                                                                                                                                                   |
| `b54191fe` | fix(price-indexer): trim Plotters features       | Skipped with price-indexer package.                                                                                                                                                                                                             |
| `b595345e` | fix(podman): stabilize age secret stamps         | Ported shared `lib/podman-compose/default.nix` byte-for-byte.                                                                                                                                                                                   |
| `6058074e` | fix(price-indexer): include font stack           | Skipped with price-indexer package.                                                                                                                                                                                                             |
| `18e512f8` | feat: Add robin core pkg/service (#2)            | Skipped Abird/Robin app and service rollout.                                                                                                                                                                                                    |
| `cbecddc6` | fix(podman): content-hash CA stamp inputs        | Ported shared `lib/podman-compose/default.nix` byte-for-byte.                                                                                                                                                                                   |
| `8688857a` | fix(systemd-user-manager): quiet verify logs     | Ported shared user-manager helper byte-for-byte.                                                                                                                                                                                                |
| `4061c8f2` | feat: add Zulip Robin adapter (#3)               | Skipped Abird/Robin app and service rollout.                                                                                                                                                                                                    |
| `60f08b30` | fix(cloudflare): remove stale OTP IdP            | Skipped gap3 Cloudflare account state.                                                                                                                                                                                                          |
| `475e8b69` | refactor(stack): centralize user filters         | Ported shared stack user-filter helpers byte-for-byte.                                                                                                                                                                                          |
| `361e5f62` | refactor(abird-nest): derive incus cert users    | Skipped Abird-nest host usage; shared Incus cert helpers were already present.                                                                                                                                                                  |
| `db7faa74` | feat(incus): add root remote cli wrapper         | Ported shared Incus module/helper byte-for-byte.                                                                                                                                                                                                |
| `0e28d41b` | docs(abird-nest): record incus cli setup         | Skipped Abird-nest docs.                                                                                                                                                                                                                        |
| `0c135c16` | feat(abird): add OpenClaw gateway                | Skipped Abird service/DNS/Terraform; retained only shared migrator profile support via later unit.                                                                                                                                              |
| `2bde2207` | feat(abird): add Hermes agent                    | Ported shared Podman helper addition byte-for-byte; skipped Abird service/DNS/Terraform.                                                                                                                                                        |
| `c89daedd` | fix(abird): show oauth2-proxy error info         | Skipped Abird oauth2-proxy service config.                                                                                                                                                                                                      |
| `a17b95da` | fix(nginx): allow oauth2 error details           | Ported shared nginx auth-location header behavior byte-for-byte.                                                                                                                                                                                |
| `2292939f` | fix(abird): mount OpenClaw config in state       | Skipped Abird OpenClaw service config.                                                                                                                                                                                                          |
| `99a9d640` | agents: add git skills                           | Ported local agent skill files byte-for-byte.                                                                                                                                                                                                   |
| `11f905d3` | feat(migrator): add runtime drain gate           | Adopted shared runtime migrator service/package/data-migrator integration. Shared modules are byte-identical; local adaptations are `flake.nix` module enablement, `pkgs/manifest.nix`, docs index, and formatter-only shell/Markdown wrapping. |

## 2026-06-08 Refresh Disposition

| Commit     | Subject                                           | Disposition                                                                                                                                                                                                     |
| ---------- | ------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `2226b060` | feat(completions): add repo CLI completions       | Already ported locally as `a23f4f1d`; repo completion bridge and docs are present.                                                                                                                              |
| `7a7d2f84` | style: fix repo lint                              | Already represented locally by migrator/statix formatting commits after the runtime-drain port.                                                                                                                 |
| `279db17a` | fix(lint): check all systems pre-push             | Already ported locally as `d93723e4`; pre-push/lint all-systems behavior is present.                                                                                                                            |
| `020d2bcf` | config(oauth2-proxy): disable debug error         | Skipped Abird oauth2-proxy host config.                                                                                                                                                                         |
| `0cfc3ceb` | refactor(migration): cleanup stale hold files     | Skipped gap3 Abird hold-module cleanup as host-specific; this repo already has runtime migrator docs and no matching `hosts/abird-migration-hold.nix` import path.                                              |
| `49b994dc` | config(tmux): ext keys, csi                       | Already ported locally as `a957bbd8`; user tmux CSI/ext-key settings and note are present.                                                                                                                      |
| `ae9258d8` | feat(incus): dns, dhcp only host ingress profiles | Already ported locally as `54e869a9`; `lib/incus/lib.nix` contains the shared DNS/DHCP-only host-ingress profile helpers.                                                                                       |
| `861967b8` | style(docs): fix markdown formatting              | Adopted in principle through the local `.agents/docs` migration and formatter pass; skipped gap3-only doc content drift.                                                                                        |
| `29708a8a` | refactor(ai): move to .agents dir                 | Adopted in principle with local docs content: moved `docs/ai` to the canonical `.agents/docs` tree and rewired run staging to `.agents/runs`; skipped gap3's Abird-specific docs additions.                     |
| `b64a8509` | chore: update flake, cleanup flake locks          | Adopted nested flake-lock cleanup and `scripts/update-flakes.sh` lock discovery; skipped gap3 root `flake.lock` update and preserved local `data/secrets/**/*.crt` ignore exception.                            |
| `11b80626` | feat(age-secrets): dry run mode                   | Ported `scripts/age-secrets.sh` byte-for-byte from gap3, including `--dry-run` and quiet runtime shell reexec.                                                                                                  |
| `148d2a03` | feat(clean-repo): script to clean up repo         | Ported `scripts/clean-repo.sh` byte-for-byte from gap3.                                                                                                                                                         |
| `6aa0246c` | chore(bash): use quiet on reexec shell            | Ported shared quiet `nix --quiet --no-warn-dirty shell` reexec behavior; adapted to local-only updater scripts; skipped gap3 `.agents` docs and `TODO.md` removal. Kept local `nixbot` Terraform secret layout. |

## 2026-06-10 Refresh Disposition

| Commit     | Subject                                               | Disposition                                                                                                                                                                           |
| ---------- | ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `0e28d41b` | docs(abird-nest): record incus cli setup              | Already reviewed; skipped Abird-nest docs.                                                                                                                                            |
| `0c135c16` | feat(abird): add OpenClaw gateway                     | Already reviewed; skipped Abird service/DNS/Terraform. Shared migrator profile support was retained from the earlier runtime-drain port.                                              |
| `2bde2207` | feat(abird): add Hermes agent                         | Already reviewed; shared Podman helper behavior was already ported, host service/DNS/Terraform skipped.                                                                               |
| `c89daedd` | fix(abird): show oauth2-proxy error info              | Already reviewed; skipped Abird oauth2-proxy host config.                                                                                                                             |
| `a17b95da` | fix(nginx): allow oauth2 error details                | Already ported as shared nginx auth-location behavior.                                                                                                                                |
| `2292939f` | fix(abird): mount OpenClaw config in state            | Already reviewed; skipped Abird OpenClaw service config.                                                                                                                              |
| `99a9d640` | agents: add git skills                                | Already ported local agent skill files.                                                                                                                                               |
| `11f905d3` | feat(migrator): add runtime drain gate                | Already ported as shared runtime migrator, data-migrator, and systemd-user-manager integration with local docs/module adaptations.                                                    |
| `2226b060` | feat(completions): add repo CLI completions           | Already ported locally; completion bridge and docs are present.                                                                                                                       |
| `7a7d2f84` | style: fix repo lint                                  | Already represented locally by formatter/statix cleanup after the migrator port.                                                                                                      |
| `279db17a` | fix(lint): check all systems pre-push                 | Already ported locally; all-systems pre-push lint behavior is present.                                                                                                                |
| `020d2bcf` | config(oauth2-proxy): disable debug error             | Skipped Abird oauth2-proxy host config.                                                                                                                                               |
| `0cfc3ceb` | refactor(migration): cleanup stale hold files         | Skipped Abird hold-module cleanup; no matching local hold-module import exists.                                                                                                       |
| `49b994dc` | config(tmux): ext keys, csi                           | Already ported locally in user tmux config and docs.                                                                                                                                  |
| `ae9258d8` | feat(incus): dns, dhcp only host ingress profiles     | Already ported locally; `lib/incus/lib.nix` contains the shared host-ingress helpers.                                                                                                 |
| `861967b8` | style(docs): fix markdown formatting                  | Adopted in principle through local `.agents/docs` formatter passes; skipped gap3-only doc drift.                                                                                      |
| `29708a8a` | refactor(ai): move to .agents dir                     | Already adopted locally with repo-specific `.agents/docs` content; skipped Abird-specific docs.                                                                                       |
| `b64a8509` | chore: update flake, cleanup flake locks              | Previously adopted nested flake-lock cleanup; root `flake.lock` drift remains intentionally local.                                                                                    |
| `11b80626` | feat(age-secrets): dry run mode                       | Already ported in `scripts/age-secrets.sh`.                                                                                                                                           |
| `148d2a03` | feat(clean-repo): script to clean up repo             | Already ported as local cleanup script support.                                                                                                                                       |
| `6aa0246c` | chore(bash): use quiet on reexec shell                | Already ported for local reexec scripts, with Terraform secret layout kept local.                                                                                                     |
| `a83b2f5f` | fix(vscode): vendoring fix                            | Adopted byte-for-byte in `lib/ext/vscode/default.nix` and `lib/ext/vscode/update.sh`.                                                                                                 |
| `1c5fa6b7` | fix(ext): update tailscale, vscode                    | Adopted byte-for-byte for `lib/ext/tailscale` and `lib/ext/vscode`; skipped one-off GitHub-token note.                                                                                |
| `2865eafb` | chore(flake): update                                  | Adopted the reusable `lib/ext/tailscale` pin state only; skipped root `flake.lock` because this repo's flake graph diverges.                                                          |
| `22408432` | refactor(scripts): localize update helpers            | Already mostly ported; retained local-only extension helpers while keeping shared `lib/ext/*/update.sh` parity.                                                                       |
| `31242bfd` | refactor(scripts): fold flake updates                 | Adopted `scripts/update.sh --only-flake`, removed `scripts/update-flakes.sh`, and updated local docs to the new command.                                                              |
| `d614ff22` | feat(update): add package reports                     | Adopted update report support, `scripts/support/report-pkgs-ext.py`, `scripts/support/report-podman-images.py`, and moved Cloudflare/Terraform helper scripts from `scripts/archive`. |
| `011ca087` | chore(ext): update safe package pins                  | Adopted byte-for-byte for `pkgs/ext/awl` and `lib/ext/stalwart-cli`.                                                                                                                  |
| `865e70f1` | chore(abird): update safe image pins                  | Skipped Abird host image pins; report tooling from the same update workflow is covered by `d614ff22` and `83c1891d`.                                                                  |
| `6d489d20` | fix(abird): heal stale mx wireguard                   | Skipped Abird Stalwart MX WireGuard host helper.                                                                                                                                      |
| `8457f275` | chore(abird): update patched app pins                 | Adopted byte-for-byte for shared `pkgs/ext/bulwarkmail`, `pkgs/ext/kanidm-server`, and `pkgs/ext/mirofish`; skipped Abird update note text.                                           |
| `f104b4d7` | chore(abird): update patched stalwart                 | Adopted byte-for-byte for shared `pkgs/ext/stalwart-server`; skipped Abird `wg-autoheal.sh` host change and update note text.                                                         |
| `bf5119c9` | refactor: make robin-core a shared library            | Skipped Robin app/package family; previous refresh intentionally skipped Robin service rollout and the local manifest does not carry those packages.                                  |
| `1a358c0f` | docs: update Robin service notes                      | Skipped Robin docs with the skipped app family.                                                                                                                                       |
| `93d27478` | fix(graphiti): use direct extraction LLM              | Adopted reusable `pkgs/support/zep-graphiti` application changes; skipped Abird host config/docs.                                                                                     |
| `e0b476e9` | fix(graphiti): harden local ingestion                 | Adopted reusable `pkgs/support/zep-graphiti` application changes; skipped Abird host config/docs.                                                                                     |
| `fa6648db` | fix(nixbot): bound remote profile reads               | Adapted portable `nixbot` bounded remote reads, SSH keepalives, timeout dependency, and retry cache clearing while preserving local Terraform secret discovery.                       |
| `1211419b` | fix(graphiti): sanitize local graph payloads          | Adopted reusable `pkgs/support/zep-graphiti` application changes.                                                                                                                     |
| `72df69b5` | fix(ollama): fail on pull API errors                  | Skipped Abird Ollama host helper.                                                                                                                                                     |
| `77cbd49f` | feat(graphiti): accept graph ontologies               | Adopted reusable `pkgs/support/zep-graphiti` ontology support.                                                                                                                        |
| `83c1891d` | fix(update): flag floating image tags                 | Adopted byte-for-byte in `scripts/support/report-podman-images.py`.                                                                                                                   |
| `6ae020b1` | fix(graphiti): sanitize ontology attributes           | Adopted reusable `pkgs/support/zep-graphiti` application changes.                                                                                                                     |
| `471a0129` | chore(abird): pin service images                      | Skipped Abird service image pins; adopted the reusable report-script behavior that recognizes floating tags.                                                                          |
| `7de2bcf2` | chore(abird): update corp images                      | Skipped Abird corp image pins.                                                                                                                                                        |
| `837ead34` | fix(abird): use ollama rag embeddings                 | Skipped Abird Open WebUI/Ollama host config and docs.                                                                                                                                 |
| `c9605e63` | Merge pull request #4 from abird-ai/ai/robin-core-lib | No direct port; constituent Robin and graphiti commits handled separately.                                                                                                            |
| `23274ddf` | fix(zep-graphiti): normalize structured output        | Adopted reusable `pkgs/support/zep-graphiti` structured-output normalization and tests.                                                                                               |
| `86a2ee46` | fix(zep-graphiti): unwrap nested list fields          | Adopted reusable `pkgs/support/zep-graphiti` nested-list normalization and tests.                                                                                                     |
| `88fb28cc` | fix(zep-graphiti): bound graph LLM calls              | Adopted reusable `pkgs/support/zep-graphiti` bounded graph-call behavior and tests; skipped Abird host timeout config/docs.                                                           |
| `2f7eee54` | fix(abird): restore nest tailnet ssh                  | Adapted portable `nixbot` bounded keyscan behavior; skipped `hosts/abird-common.nix` tailnet SSH config.                                                                              |

## Closeout Checks

- Shared files copied from the audited Abird remote branch should be
  byte-identical unless listed in Current Decisions as locally adapted.
- Validate Nix formatting and relevant eval/build checks after the full unit
  port.
- Re-run a final `master..abird/master` path audit for shared scopes before
  merging or committing.
