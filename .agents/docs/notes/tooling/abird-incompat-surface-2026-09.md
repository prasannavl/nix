# Abird incompat surface re-audit, 2026-09-18

## Scope

Repeat audit after the local shared-test-areas adoption commit `cca6266f`. The
only new configured-source commit since the prior port (`1b64de24`) is
`39dd2d5e` ("refactor(test): split shared test areas into repository identity
homes"), which `cca6266f` already ports. Nothing further was ported in this
session; this pass verifies the port and records the byte-to-byte
incompatibility surface against `abird/master` = `39dd2d5e`.

## Port verification (39dd2d5e via cca6266f)

Every file the source refactor intends to share is byte- and mode-exact in the
live tree, including the files this refactor converged for the first time:
`lib/flake/default.nix`, `lib/flake/root.nix`,
`lib/flake/tests/{default,phase-projection,service-client-endpoints,service-moves,fabric-contract,fabric-projection,service-placements}.nix`,
`lib/tests/default.nix`, `lib/services/kanidm/tests/{default.nix,README.md}`,
and `pkgs/tools/nixbot/tests/test_nixbot.py` (271 shared tests; the Pvl topology
case now lives in the repo-owned `test_nixbot_pvl.py`). Repo-identity content is
correctly split: `lib/flake/tests/pvl/` versus source's `lib/flake/tests/abird/`
plus its stack-local `lib/services/kanidm/tests/gap3.nix` and five product
promotions inside `lib/flake/repo-checks.nix`. Checks attrset: 44 generic +
`pvl-flake-isolated` here versus 56 keys in source.

## Byte-to-byte incompat surface

Common live lib/pkgs/scripts paths: 520. Exact bytes and modes: 502. Content
differences: 18, all intentional. Mode differences: 0. Source-only paths: 300
(Abird product/stack/lab trees). Pvl-only paths: 43 (desktop, hardware,
profiles, pvl stacks, and the new `tests/pvl/` identity home plus
`test_nixbot_pvl.py`). Exact-set SHA256 over sorted path/mode/blob lines without
trailing newline:
`e4aef8a6f63becc7fe3876b2f70dfc85ca00675b2a9451fe0c16eba605ce3d00`.

The 18 diverged common paths, grouped by cause:

| Path                                         | Cause                                                                                                             |
| -------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `lib/ext/nvidia/sources.nix`                 | User-requested 2026-09-07 driver rollback: 595.91.07 instead of 595.99.02.                                        |
| `lib/flake/repo-checks.nix`                  | Repo-owned identity: imports `./tests/pvl`; source adds abird identity, gap3 stack check, and product promotions. |
| `lib/hardware.nix`                           | Pvl physical firmware, Bluetooth, I2C, power management versus Abird virtual-host profile.                        |
| `lib/images/default.nix`                     | Pvl explicitly selects the Incus LXC machine profile instead of relying on the source root default.               |
| `lib/installer/config/default.nix`           | Pvl persistent GNOME installer with physical disk targets; no Abird equivalent.                                   |
| `lib/kernel.nix`                             | Pvl physical desktop kernel parameters and policy.                                                                |
| `lib/locale.nix`                             | Pvl desktop geolocation versus Abird fixed virtual-host locale.                                                   |
| `lib/network.nix`                            | Pvl global resolved DNS-over-TLS/DNSSEC and desktop split-DNS policy.                                             |
| `lib/nix.nix`                                | Pvl-owned builder cache URL/key priority (pvl-x2) instead of ci.abird.internal.                                   |
| `lib/stacks/default.nix`                     | Pvl stack/user inventory and aggregate identity; Abird product stacks not imported.                               |
| `lib/sudo.nix`                               | Pvl sudo timestamp timeout policy.                                                                                |
| `lib/systemd.nix`                            | Pvl physical suspend rate-limit policy.                                                                           |
| `pkgs/README.md`                             | Repository-owned package inventory documentation.                                                                 |
| `pkgs/cloudflare-apps/README.md`             | Pvl hostname/organization examples and references.                                                                |
| `pkgs/cloudflare-apps/llmug-hello/README.md` | Pvl app hostname/organization example.                                                                            |
| `pkgs/manifest.nix`                          | Pvl package graph; omits established absent Abird apps, bots, labs, and product services.                         |
| `pkgs/support/nats-streams/default.nix`      | Pvl generic injected `streamSpec` instead of Abird Chat Intelligence streams/bridge integration.                  |
| `pkgs/tools/abird-host-manager/README.md`    | Pvl fleet controller, inventory examples, disabled migration input guidance; implementation tree exact.           |

Eight prior divergences were eliminated by the shared-test-areas adoption:
`lib/flake/default.nix`, `lib/flake/root.nix`, `lib/flake/tests/default.nix`,
`lib/flake/tests/phase-projection.nix`, `lib/flake/tests/service-moves.nix`,
`lib/services/kanidm/tests/README.md`, `lib/services/kanidm/tests/default.nix`,
and `pkgs/tools/nixbot/tests/test_nixbot.py`.

No unexplained shared gap remains. Future consumer noted previously: adopting
`postgres-extensions.release.image`/`mkRunner` in
`hosts/pvl-x2/services/postgres.nix`.
