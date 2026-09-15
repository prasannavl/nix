# Abird repeat port parity inventory, 2026-09-16

Configured-remote source `8fc966f85ead2804983062a01f330f584596631d`, published
source `95282f5a2436563b53564cafbaa16969fc9a1f65`, target live main based at
`da81db0097b86c4574ac0182fa7f24422ad06cc9`. Both frozen source branches have
identical lib/pkgs trees. Source mode/blob identities come from git ls-tree;
target identities hash exact live bytes with Git blob framing and executable
mode. The four new updater code/test files match configured-remote source
exactly; they intentionally advance the published source tree by its two
local-only commits.

| Metric                               | Count |
| ------------------------------------ | ----: |
| Common lib/pkgs paths                |   489 |
| Exact bytes and modes                |   465 |
| Explained common content differences |    24 |
| Mode differences                     |     0 |
| Source-only paths                    |   291 |
| Pvl-only paths                       |    40 |

Exact-set SHA256 over sorted path/mode/blob lines without a trailing newline:
`536a387cbd9446db22d415c25e9cc4f8c8c18b925effd3c8395eddeec9571203`.

## Every common-path divergence

| Path                                         | Ownership/adaptation                                                                                                                             | Source blob                                | Pvl blob                                   |
| -------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------ | ------------------------------------------ |
| `lib/ext/nvidia/sources.nix`                 | Pvl user-requested 2026-09-07 driver rollback: 595.91.07 instead of 595.99.02; updater/layout otherwise exact.                                   | `14f470cb9542299845f71e16caeb928c95ed0a1e` | `7354771824c7464d2b54c0cee25b9a9abf3d5079` |
| `lib/flake/default.nix`                      | Abird-only promoted controller/application/browser checks omitted from Pvl package graph.                                                        | `4b9395e43821e046c5cc3bc9008ddaa80e484642` | `eb46c5b510a6e67c1a2c4df2178d5e8cf4930a27` |
| `lib/flake/root.nix`                         | Pvl desktop/tool inputs, disabled default placement/move/projection directories, explicit physical/LXC policy and host-agent integration.        | `944d15bff075569f12f2c0877d5983dfcfc1f2c9` | `40ddd52ddbae0b28ad9ac3f75356d25a73868c53` |
| `lib/flake/tests/default.nix`                | Pvl package/app inventory plus additive generic check naming; all shared DNS/membership fixtures adopted.                                        | `cddfec6f5edf7e1af46fd45d8adedd12f61ba741` | `db227166ccf25098156617e05d664a733dd29518` |
| `lib/flake/tests/phase-projection.nix`       | Retain synthetic placement fixture; source additions import real Abird Zulip stacks/inventory.                                                   | `4a1262f234ae7cf578f095b6e5b513fd9b886c4f` | `1dd9495d016e47e1ce5a577f7cafb31c7cf528cd` |
| `lib/flake/tests/service-moves.nix`          | Retain synthetic service-move contract; source replaces it with real Abird Zulip placement.                                                      | `21f119bdd546cafe92a68b107ee2a99631f1d302` | `14af6249c1efeb3e26975e06242ff0c673f81bc9` |
| `lib/hardware.nix`                           | Pvl physical firmware, Bluetooth, I2C and power-management policy versus Abird virtual-host profile.                                             | `a630ed520ebc7ca6bdcf4c285d41e6722eb34978` | `6e2622dd7e6c2093223ed17266af899f9b20f4d4` |
| `lib/images/default.nix`                     | Pvl explicitly selects Incus LXC machine profile instead of depending on Abird root default.                                                     | `81469993e0a93dcee2df65c1939ed487bac2f29d` | `84db571e5b3d61ddf073c87203289bf49e9e5ffd` |
| `lib/installer/config/default.nix`           | Pvl persistent GNOME installer, user and explicit physical disk targets; Abird has no equivalent targets.                                        | `8d54cd395a6f567cf816897a1a41b988c50554f9` | `cee86f742e20eaa2d55540ce35d0ad82589980cc` |
| `lib/kernel.nix`                             | Pvl physical desktop kernel parameters and policy.                                                                                               | `9b35d1b265b3fc3a30c032c5e2baa9c4ef41f291` | `feee6b37db71261712a09a0f198c29a71cd44997` |
| `lib/locale.nix`                             | Pvl desktop geolocation configuration; Abird fixed virtual-host locale policy.                                                                   | `37f945cdaf4d0afb7c364a62be8bbc1f051aff7f` | `e5f41b79f29e7ba11bbbc137fc82a428ee24ffb6` |
| `lib/network.nix`                            | Pvl global resolved DNS-over-TLS/DNSSEC and desktop split-DNS policy.                                                                            | `30e816351333d368d2b95049f4c130951ce6e9a9` | `03c1c9ddeaf7a4160610e2c7083ac09539f06390` |
| `lib/nix.nix`                                | Pvl-owned builder cache URL/key priority instead of ci.abird.internal.                                                                           | `04df33a3eab23adab2ab862141cd2fe1a403d4c8` | `2af4dce3c70c27d1588bb3f4046a9d96d6928478` |
| `lib/services/kanidm/tests/README.md`        | Shared standalone proofs retained; excluded upstream controller/VM commands replaced with frozen-source guide link.                              | `10df174a9b98841eca9a722787ef9d2654af7940` | `27bbef1b18db305761dc9fda9df64b7d4f63d904` |
| `lib/stacks/default.nix`                     | Pvl stack/user inventory and aggregate identity; Abird product stacks not imported.                                                              | `85bab85e70263739d5ab179e8c5d7c4933c25146` | `1ffe3f95da88a6632a56c3eb051d2073e350991c` |
| `lib/sudo.nix`                               | Pvl sudo timestamp timeout policy.                                                                                                               | `7529d6ff8a7da8442b4a8b0237d8cb1b14c81c0b` | `2fd6cdd340d6da0038fe0c7138d36315405bd169` |
| `lib/systemd.nix`                            | Pvl physical suspend rate-limit policy.                                                                                                          | `6c6d0344210cb2b3ea6ba11bfc53f4d347e38053` | `c1f09d7bb3b855a6f73d96c867ff6aa902dcd68f` |
| `pkgs/README.md`                             | Repository-owned package inventory documentation.                                                                                                | `f79ff0996139adb4390e0af7c268e4693d6a6f50` | `d2f505e1010ef6edf2db8a45e846c8291894f470` |
| `pkgs/cloudflare-apps/README.md`             | Pvl hostname/organization examples and references.                                                                                               | `0b7e0d1c0f82cbcecb07df245090a3da85586fee` | `1a4ee4bbdb9706b6f5808ef96f030183758d609b` |
| `pkgs/cloudflare-apps/llmug-hello/README.md` | Pvl app hostname/organization example.                                                                                                           | `eb3f5e6c322d1d2b6d6b5df7ab6e3a7e59b314d0` | `d7d91bd9650705b01c8797ea304188dc8e833d55` |
| `pkgs/manifest.nix`                          | Pvl package graph/codex wrapper; omit established absent Abird apps, bots, labs and product services.                                            | `952bf9cf9978989a67a450a8c3dac839a4da67d0` | `ed2c70f6c9e948f23eef1c31c6f7dfaba0468801` |
| `pkgs/support/nats-streams/default.nix`      | Established Pvl generic injected streamSpec instead of Abird Chat Intelligence streams/bridge integration.                                       | `4e24b48a3e32775787b036806f0dfd5e188d6c16` | `fdb96479b7568257ec205bd3516e80375d8abe47` |
| `pkgs/tools/abird-host-manager/README.md`    | Pvl fleet controller, inventory examples, and disabled migration input guidance; implementation tree exact.                                      | `11e50ceb9cf4a6daa37632d05094129204d9b6f7` | `8ee6d154d3217a982a0319873f3341eff48cefff` |
| `pkgs/tools/nixbot/tests/test_nixbot.py`     | Existing Pvl seven-host ordering regression; source now also has all three private fixture path assignments and all upstream cases are retained. | `83579819c21e18b83bd4b19a195663354e53ef26` | `030e136428602a078568cb2429b386b702701d28` |

## New shared updater unit

| Path                                                    | Mode     | Exact source/live blob                     |
| ------------------------------------------------------- | -------- | ------------------------------------------ |
| `scripts/update.sh`                                     | `100755` | `081afd0a8bc4fa470b48c9d0b3f050697c82ead8` |
| `scripts/support/podman-image-updater.py`               | `100755` | `70840cca99ede737c2e83a7f4f29a984ada306d3` |
| `scripts/support/tests/test_podman_image_updater.py`    | `100644` | `a990dbd10110641447acfa326be90b846cc8c3ec` |
| `scripts/support/tests/test_update_source_discovery.py` | `100644` | `9595a7770b7486f125bfd38a4ad774cc20477495` |

## Source-only and Pvl-only ownership

The prior
[complete source-only/Pvl-only inventory](./abird-post-1fd-parity-2026-09.md)
still covers all 290 inherited source-only exclusions and all 40 Pvl-only paths.
The one additional source-only path is
lib/flake/tests/fabric-contract-abird.nix: actual Abird stacks,
Gondor/Platform/dev addressing, routing and product placement assertions split
from the generic test. Its source check registration belongs to Abird. There are
no other new source-only paths or portable gaps.

All 20 common source files under scripts/ are also byte/mode exact to
configured-remote source after the four-file updater port. Source-only mail
operation scripts remain Abird-owned. The complete VS Code extension input and
every matching non-root lock node are exact; root flake graph remains Pvl-owned.
Pvl NVIDIA 595.91.07 remains the explicit user-requested rollback instead of
source 595.99.02.

Differences and absent product inventory are carried-forward explicit ownership
boundaries, not unfinished ports. See the
[15-commit source ledger](./abird-post-829-port-2026-09.md) for per-commit unit
classifications.
