# Abird Final-Plus-Recent Port Audit (2026-06)

## Scope

Reviewed the final 20 commits from the original anchored Abird last-60 window,
plus newer commits beyond that anchor. The original anchor was
`2c839792 fix(nixbot): skip no-op deploy waves`; the newer source head reviewed
in this pass was `3a01e3c2 style(docs): format host notes`.

Secret-bearing commits were inspected through Git metadata and path names only.
No `data/secrets/**/*.key` contents were read.

The target worktree was `worktrees/abird-final-plus-recent-port-20260626`.

## Ported Units

- `2463736c fix(dns): switch DNS record lifecycle to destroy-before-create`:
  ported the generic Cloudflare DNS lifecycle fix in
  `tf/modules/cloudflare/dns.tf`.
- `33b00a6a feat(nginx): add flexible TLS listeners`: ported the shared nginx
  high-level compose helpers in `lib/services/nginx/default.nix`.
- `d363df3f feat(stalwart): add calendar suffix option`: ported the shared
  Stalwart package patch and package wiring in `pkgs/ext/stalwart-server`.
- `af419efa feat(mail): allow shared descriptions`: ported shared mail-directory
  and Stalwart projection support for explicit shared mailbox descriptions,
  including provisioning coverage.

Already-present shared units were left unchanged:

- `5c772423 fix(podman-compose): recreate stale pids` was already present in
  `lib/podman-compose`.
- `124cfe57 fix(nixbot): promote boot entries after switch` was already present
  in `pkgs/tools/nixbot`.
- `2c839792 fix(nixbot): skip no-op deploy waves` was already present in
  `pkgs/tools/nixbot`.

## Commit Ledger

| Abird commit | Subject                                                                                        | Result                                                                                                                                |
| ------------ | ---------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `5c772423`   | `fix(podman-compose): recreate stale pids`                                                     | Already ported. Shared podman-compose helper and tests have parity.                                                                   |
| `48990383`   | `fix(outline): rotate hex secrets`                                                             | Skipped. Abird Outline secret rotation and incident docs only.                                                                        |
| `124cfe57`   | `fix(nixbot): promote boot entries after switch`                                               | Already ported. Shared nixbot behavior and tests have parity.                                                                         |
| `1d0c20a2`   | `feat(dns): add DAV/autodiscover SRV records and extract edge IP + tunnel CNAMEs as variables` | Skipped. Abird DNS records and topology data; the reusable locals/default-zone pattern should be a separate PVL DNS design if needed. |
| `90907721`   | `feat(mail): add caldav, carddav, and autodiscoverSrv domain entries and nginx routes`         | Skipped. Abird proxy and Abird service registry wiring only.                                                                          |
| `8ead0338`   | `docs: add note for DAV/autodiscover SRV records and Cloudflare dc-<id> rewrite rationale`     | Skipped. Abird operational note.                                                                                                      |
| `6381203b`   | `style: fix markdown formatting drift`                                                         | Skipped. Formatting for the skipped Abird note only.                                                                                  |
| `2463736c`   | `fix(dns): switch DNS record lifecycle to destroy-before-create`                               | Cleanly ported as a generic Cloudflare module fix.                                                                                    |
| `7d08f62f`   | `feat(zulip-robin): add recent conversation context`                                           | Skipped. The Zulip Robin package base is outside this batch and absent locally; port the whole app separately if PVL wants it.        |
| `a8f7db65`   | `feat(dav): add dav alias for stalwart`                                                        | Skipped. Abird DAV alias, registry, DNS, and docs topology.                                                                           |
| `33b00a6a`   | `feat(nginx): add flexible TLS listeners`                                                      | Cleanly ported. Shared nginx helper file has byte parity with Abird.                                                                  |
| `558f20b2`   | `fix(abird): use live ACME wildcard certs`                                                     | Skipped. Abird ACME secrets, host, common, and registry wiring.                                                                       |
| `64c85f46`   | `fix(abird): add GOA mail autoconfig`                                                          | Skipped. Abird mail autoconfig host route and Abird-specific support script.                                                          |
| `9d43a446`   | `docs(abird): record TLS discovery fixes`                                                      | Skipped. Abird host docs only.                                                                                                        |
| `8676edf5`   | `fix(auth): scope logout cookie clearing`                                                      | Skipped. Abird proxy consumer config and docs only.                                                                                   |
| `4d23453f`   | `docs(plans): add platform gap plan`                                                           | Skipped. Abird platform roadmap.                                                                                                      |
| `37ff9569`   | `fix(mail): use canonical DAV SRV target`                                                      | Skipped. Abird DAV DNS, registry, nginx, support script, and docs topology.                                                           |
| `6a466495`   | `style(docs): format host notes`                                                               | Skipped. Abird host docs only.                                                                                                        |
| `8c1e5033`   | `fix(auth): stop chaining app logout`                                                          | Skipped. Abird proxy route consumer config and docs only.                                                                             |
| `2c839792`   | `fix(nixbot): skip no-op deploy waves`                                                         | Already ported. Shared nixbot code and tests have parity.                                                                             |
| `f6a23a3c`   | `docs(activesync): record push debug path`                                                     | Skipped. Abird ActiveSync host note.                                                                                                  |
| `d363df3f`   | `feat(stalwart): add calendar suffix option`                                                   | Cleanly ported. Shared Stalwart package files have byte parity with Abird.                                                            |
| `af419efa`   | `feat(mail): allow shared descriptions`                                                        | Cleanly ported. Shared mail-directory and Stalwart files have byte parity with Abird.                                                 |
| `cbec5626`   | `feat(abird): add org calendar group`                                                          | Skipped. Abird organization group data and host docs; it consumes the shared description support but is not shared data.              |
| `ebc12b72`   | `style(nginx): format id routes`                                                               | Skipped. Abird proxy route formatting only.                                                                                           |
| `3a01e3c2`   | `style(docs): format host notes`                                                               | Skipped. Abird host docs only.                                                                                                        |

## Parity Audit

Byte-for-byte parity with Abird after this pass:

- `lib/podman-compose/helper.sh`
- `lib/podman-compose/tests/fake_podman.py`
- `lib/podman-compose/tests/test_helper.py`
- `lib/services/mail-directory/default.nix`
- `lib/services/nginx/default.nix`
- `lib/services/stalwart/default.nix`
- `lib/services/stalwart/tests/provisioning.nix`
- `pkgs/ext/stalwart-server/calendar-default-display-name-policy.patch`
- `pkgs/ext/stalwart-server/default.nix`
- `pkgs/tools/nixbot/nixbot.sh`
- `pkgs/tools/nixbot/tests/test_nixbot.py`

Intentional divergences:

- Abird host, proxy, registry, ACME, DAV, GOA autoconfig, ActiveSync, auth, and
  platform docs under Abird-owned paths were skipped.
- Abird `data/secrets/abird/**` registry and encrypted secret changes were
  skipped.
- Abird `tf/cloudflare-dns` records and constants were skipped because they are
  topology data; only the shared module lifecycle behavior was ported.
- Zulip Robin remains absent locally. The batch commit only changes an existing
  app, so porting it without the earlier package history would be incomplete.

## Validation

- `cmp -s` byte-parity checks for the shared files listed above.
- `alejandra --check` on changed Nix files.
- `tofu fmt -check tf/modules/cloudflare/dns.tf`.
- `nix build --no-link .#checks.x86_64-linux.lib-flake-isolated
  .#checks.x86_64-linux.lib-profiles-incus-lxc`.
- `nix eval --raw .#packages.x86_64-linux.stalwart-server.drvPath` with the new
  patch file made index-visible via `git add -N` for validation.
- Direct `nix build --no-link --impure --expr ...` of
  `lib/services/stalwart/tests/default.nix` `provisioning`.
- `git diff --check`.
