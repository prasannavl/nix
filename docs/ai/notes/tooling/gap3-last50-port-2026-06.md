# gap3 Last-50 Port Ledger, 2026-06

## Scope

Selective port of the refreshed last 50 commits on `gap3/master` as of
2026-06-01, first ending at `254bdf52 docs(incus): format vm support note`, then
refreshed through `4f11011c fix(git): reject dirty pre-push lint`.

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
- Adapted local `docs/ai/notes/nixbot/deploy-system.md` with the upstream
  `dev-build` result directory semantics. Skipped importing gap3's consolidated
  nixbot operations note because this repo keeps that content split into local
  note files.
- Keep Abird/GAP3 host services, DNS, route usage, and secret wiring skipped
  unless a matching local service stack is explicitly requested.

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

## Closeout Checks

- Shared files copied from `gap3/master` should be byte-identical unless listed
  in Current Decisions as locally adapted.
- Validate Nix formatting and relevant eval/build checks after the full unit
  port.
- Re-run a final `master..gap3/master` path audit for shared scopes before
  merging or committing.
