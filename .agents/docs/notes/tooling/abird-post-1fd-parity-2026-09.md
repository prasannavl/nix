# Abird/Pvl byte and mode parity, 2026-09-15

Frozen source `829d81ed59b06d6d4500c92c5917facabcc92b26`; main-tree port based
at `1b11287041054bf76a3a99a3d0d0884c9992962e`, with implementation through
`5a836363` transferred byte/mode exactly from the reviewed candidate. Whole-tree
inventory includes every regular-file path under `lib/**` and `pkgs/**` (there
is no `pkg/` root). Source metadata comes from Git trees; target blobs hash
exact live bytes using Git blob framing and executable mode. New candidate files
are included. No secret paths are in this comparison.

| Metric                               | Count |
| ------------------------------------ | ----: |
| Common paths                         |   489 |
| Exact bytes and Git mode             |   464 |
| Explained common content divergences |    25 |
| Mode divergences                     |     0 |
| Source-only paths                    |   290 |
| Pvl-only paths                       |    40 |

Exact-set SHA-256 over sorted `path mode blob` lines:
`547d1f1a47eb72ab2e4efa68289d706effc0c18392e79ec75e3013babb4442e6`.

All common paths in complete Incus, Ollama, native host-agent, native
host-manager implementation/tests, and shared package/flake runtime helpers are
exact. The host-manager README and explicitly listed Pvl policy/test/doc files
below are exceptions. All common `scripts/` implementation and test files also
match the frozen source; source-only mail operation scripts remain Abird-owned.
Matching `crane`, `home-manager`, `nixpkgs`, `unstable` and `vscode-ext` lock
nodes are exact; the complete root lock graph is intentionally Pvl-owned.

## Every common-path divergence

| Path                                         | Pvl reason                                                                                                                                | Source blob                                | Candidate blob                             |
| -------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------ | ------------------------------------------ |
| `lib/ext/nvidia/sources.nix`                 | Pvl user-requested 2026-09-07 driver rollback: 595.91.07 instead of 595.99.02; updater/layout otherwise exact.                            | `14f470cb9542299845f71e16caeb928c95ed0a1e` | `7354771824c7464d2b54c0cee25b9a9abf3d5079` |
| `lib/flake/default.nix`                      | Abird-only promoted controller/application/browser checks omitted from Pvl package graph.                                                 | `4b9395e43821e046c5cc3bc9008ddaa80e484642` | `eb46c5b510a6e67c1a2c4df2178d5e8cf4930a27` |
| `lib/flake/root.nix`                         | Pvl desktop/tool inputs, disabled default placement/move/projection directories, explicit physical/LXC policy and host-agent integration. | `944d15bff075569f12f2c0877d5983dfcfc1f2c9` | `40ddd52ddbae0b28ad9ac3f75356d25a73868c53` |
| `lib/flake/tests/default.nix`                | Pvl package/app inventory plus additive generic check naming; all shared DNS/membership fixtures adopted.                                 | `fae33e4f1d2b2950506acc776f960b04ab919fbb` | `db227166ccf25098156617e05d664a733dd29518` |
| `lib/flake/tests/fabric-contract.nix`        | Independent synthetic fabric fixture replaces real Abird stack topology; generic validation and coverage retained.                        | `51a05c7fec05dc6276ba78fdd61791948b702754` | `baef10fc0ef1ac16f1adc693b0644cabb23f255a` |
| `lib/flake/tests/phase-projection.nix`       | Retain synthetic placement fixture; source additions import real Abird Zulip stacks/inventory.                                            | `4a1262f234ae7cf578f095b6e5b513fd9b886c4f` | `1dd9495d016e47e1ce5a577f7cafb31c7cf528cd` |
| `lib/flake/tests/service-moves.nix`          | Retain synthetic service-move contract; source replaces it with real Abird Zulip placement.                                               | `21f119bdd546cafe92a68b107ee2a99631f1d302` | `14af6249c1efeb3e26975e06242ff0c673f81bc9` |
| `lib/hardware.nix`                           | Pvl physical firmware, Bluetooth, I2C and power-management policy versus Abird virtual-host profile.                                      | `a630ed520ebc7ca6bdcf4c285d41e6722eb34978` | `6e2622dd7e6c2093223ed17266af899f9b20f4d4` |
| `lib/images/default.nix`                     | Pvl explicitly selects Incus LXC machine profile instead of depending on Abird root default.                                              | `81469993e0a93dcee2df65c1939ed487bac2f29d` | `84db571e5b3d61ddf073c87203289bf49e9e5ffd` |
| `lib/installer/config/default.nix`           | Pvl persistent GNOME installer, user and explicit physical disk targets; Abird has no equivalent targets.                                 | `8d54cd395a6f567cf816897a1a41b988c50554f9` | `cee86f742e20eaa2d55540ce35d0ad82589980cc` |
| `lib/kernel.nix`                             | Pvl physical desktop kernel parameters and policy.                                                                                        | `9b35d1b265b3fc3a30c032c5e2baa9c4ef41f291` | `feee6b37db71261712a09a0f198c29a71cd44997` |
| `lib/locale.nix`                             | Pvl desktop geolocation configuration; Abird fixed virtual-host locale policy.                                                            | `37f945cdaf4d0afb7c364a62be8bbc1f051aff7f` | `e5f41b79f29e7ba11bbbc137fc82a428ee24ffb6` |
| `lib/network.nix`                            | Pvl global resolved DNS-over-TLS/DNSSEC and desktop split-DNS policy.                                                                     | `30e816351333d368d2b95049f4c130951ce6e9a9` | `03c1c9ddeaf7a4160610e2c7083ac09539f06390` |
| `lib/nix.nix`                                | Pvl-owned builder cache URL/key priority instead of ci.abird.internal.                                                                    | `04df33a3eab23adab2ab862141cd2fe1a403d4c8` | `2af4dce3c70c27d1588bb3f4046a9d96d6928478` |
| `lib/services/kanidm/tests/README.md`        | Shared standalone proofs retained; excluded upstream controller/VM commands replaced with frozen-source guide link.                       | `10df174a9b98841eca9a722787ef9d2654af7940` | `27bbef1b18db305761dc9fda9df64b7d4f63d904` |
| `lib/stacks/default.nix`                     | Pvl stack/user inventory and aggregate identity; Abird product stacks not imported.                                                       | `85bab85e70263739d5ab179e8c5d7c4933c25146` | `1ffe3f95da88a6632a56c3eb051d2073e350991c` |
| `lib/sudo.nix`                               | Pvl sudo timestamp timeout policy.                                                                                                        | `7529d6ff8a7da8442b4a8b0237d8cb1b14c81c0b` | `2fd6cdd340d6da0038fe0c7138d36315405bd169` |
| `lib/systemd.nix`                            | Pvl physical suspend rate-limit policy.                                                                                                   | `6c6d0344210cb2b3ea6ba11bfc53f4d347e38053` | `c1f09d7bb3b855a6f73d96c867ff6aa902dcd68f` |
| `pkgs/README.md`                             | Repository-owned package inventory documentation.                                                                                         | `f79ff0996139adb4390e0af7c268e4693d6a6f50` | `d2f505e1010ef6edf2db8a45e846c8291894f470` |
| `pkgs/cloudflare-apps/README.md`             | Pvl hostname/organization examples and references.                                                                                        | `0b7e0d1c0f82cbcecb07df245090a3da85586fee` | `1a4ee4bbdb9706b6f5808ef96f030183758d609b` |
| `pkgs/cloudflare-apps/llmug-hello/README.md` | Pvl app hostname/organization example.                                                                                                    | `eb3f5e6c322d1d2b6d6b5df7ab6e3a7e59b314d0` | `d7d91bd9650705b01c8797ea304188dc8e833d55` |
| `pkgs/manifest.nix`                          | Pvl package graph/codex wrapper; omit established absent Abird apps, bots, labs and product services.                                     | `952bf9cf9978989a67a450a8c3dac839a4da67d0` | `ed2c70f6c9e948f23eef1c31c6f7dfaba0468801` |
| `pkgs/support/nats-streams/default.nix`      | Established Pvl generic injected streamSpec instead of Abird Chat Intelligence streams/bridge integration.                                | `4e24b48a3e32775787b036806f0dfd5e188d6c16` | `fdb96479b7568257ec205bd3516e80375d8abe47` |
| `pkgs/tools/abird-host-manager/README.md`    | Pvl fleet controller, inventory examples, and disabled migration input guidance; implementation tree exact.                               | `11e50ceb9cf4a6daa37632d05094129204d9b6f7` | `8ee6d154d3217a982a0319873f3341eff48cefff` |
| `pkgs/tools/nixbot/tests/test_nixbot.py`     | Existing Pvl topology regression plus three private fixture path assignments; all upstream cases retained.                                | `255f745484c5155167a236ca40876cac63420ec6` | `030e136428602a078568cb2429b386b702701d28` |

## Changed source units

This subset contains every final-source `lib/**`/`pkgs/**` path touched in the
42-commit range. Missing final-source paths are owned exclusions, with complete
inventory below. Intermediate versions and deleted topology files are
dispositioned in the commit ledger.

| Final-source changed-path outcome | Count |
| --------------------------------- | ----: |
| Exact                             |    71 |
| Explicit adaptation               |     7 |
| Source-owned exclusion            |    50 |

## Complete source-only inventory

These paths are not missing ports. Concrete stacks and Abird
product/app/protocol/lab/hosting inventory were excluded in earlier Pvl audits.
This range adds product identity/auth/UI work without changing their ownership.
ExcaliDash and OpenDesign remain explicitly excluded (see prior July/August port
notes); the new OpenDesign sources record does not require importing the absent
package. Generic fabric helpers formerly absent are now adopted and therefore
appear among common paths.

| Path                                                                                       | Ownership exclusion                                   | Changed in range |
| ------------------------------------------------------------------------------------------ | ----------------------------------------------------- | ---------------- |
| `lib/services/excalidash/default.nix`                                                      | Established absent ExcaliDash product/consumer        | no               |
| `lib/services/excalidash/helper.sh`                                                        | Established absent ExcaliDash product/consumer        | no               |
| `lib/stacks/abird-dev.nix`                                                                 | Abird concrete stack/topology/inventory               | yes              |
| `lib/stacks/abird-platform.nix`                                                            | Abird concrete stack/topology/inventory               | yes              |
| `lib/stacks/abird-registry.nix`                                                            | Abird concrete stack/topology/inventory               | no               |
| `lib/stacks/abird-stacks.nix`                                                              | Abird concrete stack/topology/inventory               | yes              |
| `lib/stacks/abird.nix`                                                                     | Abird concrete stack/topology/inventory               | yes              |
| `lib/stacks/gap3.nix`                                                                      | Abird concrete stack/topology/inventory               | no               |
| `lib/stacks/limits/abird-dev.nix`                                                          | Abird concrete stack/topology/inventory               | no               |
| `lib/stacks/limits/gap3-gondor.nix`                                                        | Abird concrete stack/topology/inventory               | no               |
| `lib/sway.nix`                                                                             | Inherited Abird desktop module; outside current range | no               |
| `pkgs/apps/abird-app/.gitignore`                                                           | Abird agency product/application/protocol             | no               |
| `pkgs/apps/abird-app/README.md`                                                            | Abird agency product/application/protocol             | yes              |
| `pkgs/apps/abird-app/default.nix`                                                          | Abird agency product/application/protocol             | yes              |
| `pkgs/apps/abird-app/flake.nix`                                                            | Abird agency product/application/protocol             | no               |
| `pkgs/apps/abird-app/frontend-dist/index.html`                                             | Abird agency product/application/protocol             | no               |
| `pkgs/apps/abird-app/platform/linux.nix`                                                   | Abird agency product/application/protocol             | no               |
| `pkgs/apps/abird-app/platform/macos.nix`                                                   | Abird agency product/application/protocol             | no               |
| `pkgs/apps/abird-app/platform/windows.nix`                                                 | Abird agency product/application/protocol             | no               |
| `pkgs/apps/abird-app/src-tauri/Cargo.toml`                                                 | Abird agency product/application/protocol             | yes              |
| `pkgs/apps/abird-app/src-tauri/build.rs`                                                   | Abird agency product/application/protocol             | no               |
| `pkgs/apps/abird-app/src-tauri/icons/icon.png`                                             | Abird agency product/application/protocol             | no               |
| `pkgs/apps/abird-app/src-tauri/icons/icon.svg`                                             | Abird agency product/application/protocol             | no               |
| `pkgs/apps/abird-app/src-tauri/src/main.rs`                                                | Abird agency product/application/protocol             | yes              |
| `pkgs/apps/abird-app/src-tauri/src/native_callback.rs`                                     | Abird agency product/application/protocol             | yes              |
| `pkgs/apps/abird-app/src-tauri/tauri.conf.json`                                            | Abird agency product/application/protocol             | no               |
| `pkgs/apps/abird-app/src-tauri/tauri.linux.conf.json`                                      | Abird agency product/application/protocol             | no               |
| `pkgs/apps/abird-app/tests/desktop-service.nix`                                            | Abird agency product/application/protocol             | yes              |
| `pkgs/bots/parrot-core/Cargo.toml`                                                         | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/bots/parrot-core/default.nix`                                                        | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/bots/parrot-core/src/lib.rs`                                                         | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/bots/robin-core/Cargo.toml`                                                          | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/bots/robin-core/README.md`                                                           | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/bots/robin-core/default.nix`                                                         | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/bots/robin-core/flake.nix`                                                           | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/bots/robin-core/src/lib.rs`                                                          | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/bots/tg-parrot/Cargo.toml`                                                           | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/bots/tg-parrot/README.md`                                                            | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/bots/tg-parrot/default.nix`                                                          | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/bots/tg-parrot/flake.nix`                                                            | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/bots/tg-parrot/src/main.rs`                                                          | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/bots/zulip-parrot/Cargo.toml`                                                        | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/bots/zulip-parrot/README.md`                                                         | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/bots/zulip-parrot/default.nix`                                                       | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/bots/zulip-parrot/flake.nix`                                                         | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/bots/zulip-parrot/src/main.rs`                                                       | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/bots/zulip-robin/Cargo.toml`                                                         | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/bots/zulip-robin/README.md`                                                          | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/bots/zulip-robin/default.nix`                                                        | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/bots/zulip-robin/flake.nix`                                                          | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/bots/zulip-robin/src/main.rs`                                                        | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/examples/edi-ast-parser-rs/.envrc`                                                   | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/examples/edi-ast-parser-rs/Cargo.toml`                                               | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/examples/edi-ast-parser-rs/default.nix`                                              | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/examples/edi-ast-parser-rs/flake.nix`                                                | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/examples/edi-ast-parser-rs/sample.edi`                                               | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/examples/edi-ast-parser-rs/src/lib.rs`                                               | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/examples/edi-ast-parser-rs/src/main.rs`                                              | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/ext/gcp-cloud-run/README.md`                                                         | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/ext/gcp-cloud-run/chat-intelligence/README.md`                                       | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/ext/gcp-cloud-run/chat-intelligence/destroy.sh`                                      | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/ext/gcp-cloud-run/chat-intelligence/make.sh`                                         | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/ext/gcp-cloud-run/sidecar/README.md`                                                 | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/ext/gcp-cloud-run/sidecar/baked-secrets/.gitignore`                                  | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/ext/gcp-cloud-run/sidecar/make.sh`                                                   | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/ext/gcp-cloud-run/sidecar/sidecar-nats-leaf.dockerfile`                              | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/ext/gcp-cloud-run/sidecar/sidecar-nats-leaf.entrypoint.sh`                           | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/ext/gcp-cloud-run/sidecar/sidecar.dockerfile`                                        | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/ext/gcp-cloud-run/sidecar/sidecar.entrypoint.sh`                                     | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/ext/gcp-cloud-run/xtest/.dockerignore`                                               | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/ext/gcp-cloud-run/xtest/.gitignore`                                                  | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/ext/gcp-cloud-run/xtest/Dockerfile`                                                  | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/ext/gcp-cloud-run/xtest/README.md`                                                   | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/ext/gcp-cloud-run/xtest/deno.json`                                                   | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/ext/gcp-cloud-run/xtest/deno.lock`                                                   | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/ext/gcp-cloud-run/xtest/main.ts`                                                     | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/ext/gcp-cloud-run/xtest/scripts/01-setup.sh`                                         | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/ext/gcp-cloud-run/xtest/scripts/02-start.sh`                                         | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/ext/gcp-cloud-run/xtest/scripts/03-test.sh`                                          | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/ext/gcp-cloud-run/xtest/scripts/04-destroy.sh`                                       | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/ext/gcp-cloud-run/xtest/scripts/common.sh`                                           | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/ext/gcp-cloud-run/xtest/scripts/make.sh`                                             | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/ext/opendesign/default.nix`                                                          | Established absent OpenDesign package/consumer        | yes              |
| `pkgs/ext/opendesign/sources.nix`                                                          | Established absent OpenDesign package/consumer        | yes              |
| `pkgs/labs/rust-tictactoe/Cargo.lock`                                                      | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/rust-tictactoe/Cargo.toml`                                                      | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/rust-tictactoe/README.md`                                                       | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/rust-tictactoe/Trunk.toml`                                                      | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/rust-tictactoe/assets/fonts/Courier_Prime/CourierPrime-Bold.ttf`                | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/rust-tictactoe/assets/fonts/Courier_Prime/CourierPrime-BoldItalic.ttf`          | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/rust-tictactoe/assets/fonts/Courier_Prime/CourierPrime-Italic.ttf`              | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/rust-tictactoe/assets/fonts/Courier_Prime/CourierPrime-Regular.ttf`             | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/rust-tictactoe/assets/fonts/Courier_Prime/OFL.txt`                              | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/rust-tictactoe/assets/sounds/clap.mp3`                                          | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/rust-tictactoe/assets/sounds/knock.mp3`                                         | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/rust-tictactoe/assets/sounds/tap.mp3`                                           | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/rust-tictactoe/audio-unlock.js`                                                 | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/rust-tictactoe/default.nix`                                                     | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/rust-tictactoe/flake.nix`                                                       | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/rust-tictactoe/index.html`                                                      | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/rust-tictactoe/src/game.rs`                                                     | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/rust-tictactoe/src/game/ai.rs`                                                  | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/rust-tictactoe/src/game/assets.rs`                                              | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/rust-tictactoe/src/game/board.rs`                                               | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/rust-tictactoe/src/game/gameplay.rs`                                            | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/rust-tictactoe/src/game/state.rs`                                               | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/rust-tictactoe/src/game/ui.rs`                                                  | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/rust-tictactoe/src/main.rs`                                                     | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/.gitignore`                                                  | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/Cargo.lock`                                                  | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/Cargo.toml`                                                  | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/README.md`                                                   | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/crates/indexer-data/Cargo.toml`                              | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/crates/indexer-data/src/coingecko_onchain.rs`                | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/crates/indexer-data/src/drift_client.rs`                     | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/crates/indexer-data/src/drift_perp.rs`                       | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/crates/indexer-data/src/exa_search.rs`                       | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/crates/indexer-data/src/jupiter_quote.rs`                    | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/crates/indexer-data/src/lib.rs`                              | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/crates/indexer-data/src/x_search.rs`                         | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/crates/indexer/Cargo.toml`                                   | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/crates/indexer/src/app.rs`                                   | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/crates/indexer/src/app/config.rs`                            | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/crates/indexer/src/app/db.rs`                                | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/crates/indexer/src/main.rs`                                  | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/crates/leptos-ui/.gitignore`                                 | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/crates/leptos-ui/Cargo.toml`                                 | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/crates/leptos-ui/LICENSE`                                    | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/crates/leptos-ui/README.md`                                  | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/crates/leptos-ui/end2end/.gitignore`                         | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/crates/leptos-ui/end2end/package-lock.json`                  | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/crates/leptos-ui/end2end/package.json`                       | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/crates/leptos-ui/end2end/playwright.config.ts`               | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/crates/leptos-ui/end2end/tests/example.spec.ts`              | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/crates/leptos-ui/end2end/tsconfig.json`                      | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/crates/leptos-ui/public/favicon.ico`                         | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/crates/leptos-ui/public/vendor/apexcharts/apexcharts.min.js` | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/crates/leptos-ui/src/app.rs`                                 | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/crates/leptos-ui/src/chart.rs`                               | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/crates/leptos-ui/src/config.rs`                              | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/crates/leptos-ui/src/db.rs`                                  | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/crates/leptos-ui/src/lib.rs`                                 | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/crates/leptos-ui/src/main.rs`                                | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/crates/leptos-ui/src/server.rs`                              | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/crates/leptos-ui/src/state.rs`                               | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/crates/leptos-ui/src/ui.rs`                                  | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/crates/leptos-ui/src/ui/types.rs`                            | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/crates/leptos-ui/style/main.scss`                            | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/data/.gitignore`                                             | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/default.nix`                                                 | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/flake.nix`                                                   | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/sample_price_indexer.toml`                                   | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/skills-lock.json`                                            | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/vendor/apexcharts-rs/.cargo-ok`                              | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/vendor/apexcharts-rs/.cargo_vcs_info.json`                   | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/vendor/apexcharts-rs/.github/workflows/build.yaml`           | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/vendor/apexcharts-rs/.github/workflows/deploy.yaml`          | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/vendor/apexcharts-rs/.gitignore`                             | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/vendor/apexcharts-rs/Cargo.toml`                             | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/vendor/apexcharts-rs/Cargo.toml.orig`                        | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/vendor/apexcharts-rs/LICENSE`                                | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/vendor/apexcharts-rs/README.md`                              | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/vendor/apexcharts-rs/assets/area_chart.png`                  | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/vendor/apexcharts-rs/assets/bar_chart.png`                   | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/vendor/apexcharts-rs/assets/column_chart.png`                | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/vendor/apexcharts-rs/assets/line_chart.png`                  | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/vendor/apexcharts-rs/assets/pie_chart.png`                   | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/vendor/apexcharts-rs/src/bindings/chart.js`                  | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/vendor/apexcharts-rs/src/bindings/mod.rs`                    | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/vendor/apexcharts-rs/src/leptos.rs`                          | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/vendor/apexcharts-rs/src/lib.rs`                             | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/vendor/apexcharts-rs/src/options.rs`                         | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/labs/web3-price-indexer/vendor/apexcharts-rs/src/yew.rs`                             | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/srv/README.md`                                                                       | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/srv/abird-agent/Cargo.toml`                                                          | Abird agency product/application/protocol             | yes              |
| `pkgs/srv/abird-agent/README.md`                                                           | Abird agency product/application/protocol             | yes              |
| `pkgs/srv/abird-agent/cell-image.nix`                                                      | Abird agency product/application/protocol             | no               |
| `pkgs/srv/abird-agent/default.nix`                                                         | Abird agency product/application/protocol             | no               |
| `pkgs/srv/abird-agent/flake.nix`                                                           | Abird agency product/application/protocol             | no               |
| `pkgs/srv/abird-agent/module.nix`                                                          | Abird agency product/application/protocol             | yes              |
| `pkgs/srv/abird-agent/src/auth.rs`                                                         | Abird agency product/application/protocol             | yes              |
| `pkgs/srv/abird-agent/src/auth/background.rs`                                              | Abird agency product/application/protocol             | yes              |
| `pkgs/srv/abird-agent/src/backup.rs`                                                       | Abird agency product/application/protocol             | yes              |
| `pkgs/srv/abird-agent/src/bin/abird-agent-cell.rs`                                         | Abird agency product/application/protocol             | no               |
| `pkgs/srv/abird-agent/src/cell/mod.rs`                                                     | Abird agency product/application/protocol             | yes              |
| `pkgs/srv/abird-agent/src/doctor.rs`                                                       | Abird agency product/application/protocol             | yes              |
| `pkgs/srv/abird-agent/src/events.rs`                                                       | Abird agency product/application/protocol             | yes              |
| `pkgs/srv/abird-agent/src/execution.rs`                                                    | Abird agency product/application/protocol             | yes              |
| `pkgs/srv/abird-agent/src/identity.rs`                                                     | Abird agency product/application/protocol             | yes              |
| `pkgs/srv/abird-agent/src/lib.rs`                                                          | Abird agency product/application/protocol             | yes              |
| `pkgs/srv/abird-agent/src/main.rs`                                                         | Abird agency product/application/protocol             | yes              |
| `pkgs/srv/abird-agent/src/orchestration.rs`                                                | Abird agency product/application/protocol             | yes              |
| `pkgs/srv/abird-agent/src/provider.rs`                                                     | Abird agency product/application/protocol             | yes              |
| `pkgs/srv/abird-agent/src/schedule.rs`                                                     | Abird agency product/application/protocol             | yes              |
| `pkgs/srv/abird-agent/src/store.rs`                                                        | Abird agency product/application/protocol             | yes              |
| `pkgs/srv/abird-agent/src/store/background.rs`                                             | Abird agency product/application/protocol             | yes              |
| `pkgs/srv/abird-agent/tests/contained-cell.nix`                                            | Abird agency product/application/protocol             | yes              |
| `pkgs/srv/abird-agent/tests/contained-diagnostic.nix`                                      | Abird agency product/application/protocol             | yes              |
| `pkgs/srv/abird-agent/tests/contained-fixture.nix`                                         | Abird agency product/application/protocol             | yes              |
| `pkgs/srv/abird-agent/tests/fake-provider.py`                                              | Abird agency product/application/protocol             | no               |
| `pkgs/srv/abird-agent/tests/hosted_login_return_proof.cjs`                                 | Abird agency product/application/protocol             | yes              |
| `pkgs/srv/abird-agent/tests/hosted_login_return_proof.py`                                  | Abird agency product/application/protocol             | yes              |
| `pkgs/srv/abird-agent/tests/identity_browser_proof.cjs`                                    | Abird agency product/application/protocol             | yes              |
| `pkgs/srv/abird-agent/tests/identity_fixture.py`                                           | Abird agency product/application/protocol             | yes              |
| `pkgs/srv/abird-agent/tests/identity_proof.py`                                             | Abird agency product/application/protocol             | yes              |
| `pkgs/srv/abird-agent/tests/operational_cli.rs`                                            | Abird agency product/application/protocol             | yes              |
| `pkgs/srv/abird-agent/tests/phase2a_e2e.rs`                                                | Abird agency product/application/protocol             | yes              |
| `pkgs/srv/abird-agent/tests/signal_shutdown.rs`                                            | Abird agency product/application/protocol             | yes              |
| `pkgs/srv/ingest/.envrc`                                                                   | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/srv/ingest/Cargo.toml`                                                               | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/srv/ingest/README.md`                                                                | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/srv/ingest/default.nix`                                                              | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/srv/ingest/flake.nix`                                                                | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/srv/ingest/src/main.rs`                                                              | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/srv/llm/.envrc`                                                                      | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/srv/llm/Cargo.toml`                                                                  | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/srv/llm/README.md`                                                                   | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/srv/llm/default.nix`                                                                 | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/srv/llm/flake.nix`                                                                   | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/srv/llm/src/main.rs`                                                                 | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/srv/search/Cargo.toml`                                                               | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/srv/search/README.md`                                                                | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/srv/search/default.nix`                                                              | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/srv/search/flake.nix`                                                                | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/srv/search/src/main.rs`                                                              | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/srv/trading-api/.envrc`                                                              | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/srv/trading-api/Cargo.toml`                                                          | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/srv/trading-api/README.md`                                                           | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/srv/trading-api/default.nix`                                                         | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/srv/trading-api/flake.nix`                                                           | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/srv/trading-api/src/main.rs`                                                         | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/srv/trading-processor/.envrc`                                                        | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/srv/trading-processor/Cargo.toml`                                                    | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/srv/trading-processor/README.md`                                                     | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/srv/trading-processor/default.nix`                                                   | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/srv/trading-processor/flake.nix`                                                     | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/srv/trading-processor/src/main.rs`                                                   | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/srv/trading-transformer-excel/.envrc`                                                | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/srv/trading-transformer-excel/Cargo.toml`                                            | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/srv/trading-transformer-excel/README.md`                                             | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/srv/trading-transformer-excel/default.nix`                                           | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/srv/trading-transformer-excel/flake.nix`                                             | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/srv/trading-transformer-excel/src/main.rs`                                           | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/support/abird-protocol/Cargo.toml`                                                   | Abird agency product/application/protocol             | no               |
| `pkgs/support/abird-protocol/README.md`                                                    | Abird agency product/application/protocol             | no               |
| `pkgs/support/abird-protocol/default.nix`                                                  | Abird agency product/application/protocol             | no               |
| `pkgs/support/abird-protocol/flake.nix`                                                    | Abird agency product/application/protocol             | no               |
| `pkgs/support/abird-protocol/src/lib.rs`                                                   | Abird agency product/application/protocol             | yes              |
| `pkgs/support/nats-streams/specs/chat-intelligence.nix`                                    | Abird Chat Intelligence stream specification          | no               |
| `pkgs/tools/abird-host-manager/examples/abird-gondor-zulip.json`                           | Abird Gondor/Zulip topology example                   | no               |
| `pkgs/tools/postgres-queue/Cargo.toml`                                                     | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/tools/postgres-queue/README.md`                                                      | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/tools/postgres-queue/default.nix`                                                    | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/tools/postgres-queue/flake.nix`                                                      | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/tools/postgres-queue/src/bin/consumer.rs`                                            | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/tools/postgres-queue/src/bin/orchestrator.rs`                                        | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/tools/postgres-queue/src/bin/producer.rs`                                            | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/tools/postgres-queue/src/lib.rs`                                                     | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/tools/sqlite-queue/Cargo.toml`                                                       | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/tools/sqlite-queue/README.md`                                                        | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/tools/sqlite-queue/default.nix`                                                      | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/tools/sqlite-queue/flake.nix`                                                        | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/tools/sqlite-queue/src/bin/consumer.rs`                                              | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/tools/sqlite-queue/src/bin/orchestrator.rs`                                          | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/tools/sqlite-queue/src/bin/producer.rs`                                              | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/tools/sqlite-queue/src/lib.rs`                                                       | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/tools/sqlite-queue/src/parallel-impl-test.rs`                                        | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/web/abird-web/Cargo.toml`                                                            | Abird agency product/application/protocol             | yes              |
| `pkgs/web/abird-web/README.md`                                                             | Abird agency product/application/protocol             | yes              |
| `pkgs/web/abird-web/Trunk.toml`                                                            | Abird agency product/application/protocol             | no               |
| `pkgs/web/abird-web/default.nix`                                                           | Abird agency product/application/protocol             | yes              |
| `pkgs/web/abird-web/flake.nix`                                                             | Abird agency product/application/protocol             | no               |
| `pkgs/web/abird-web/index.html`                                                            | Abird agency product/application/protocol             | no               |
| `pkgs/web/abird-web/public/favicon.svg`                                                    | Abird agency product/application/protocol             | no               |
| `pkgs/web/abird-web/src/application.rs`                                                    | Abird agency product/application/protocol             | yes              |
| `pkgs/web/abird-web/src/controller.rs`                                                     | Abird agency product/application/protocol             | yes              |
| `pkgs/web/abird-web/src/main.rs`                                                           | Abird agency product/application/protocol             | no               |
| `pkgs/web/abird-web/src/ui/mod.rs`                                                         | Abird agency product/application/protocol             | yes              |
| `pkgs/web/abird-web/style.css`                                                             | Abird agency product/application/protocol             | yes              |
| `pkgs/web/abird-web/tests/browser/phase2a.spec.js`                                         | Abird agency product/application/protocol             | yes              |
| `pkgs/web/gap3-hello/.envrc`                                                               | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/web/gap3-hello/Cargo.toml`                                                           | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/web/gap3-hello/README.md`                                                            | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/web/gap3-hello/Trunk.toml`                                                           | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/web/gap3-hello/default.nix`                                                          | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/web/gap3-hello/flake.nix`                                                            | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/web/gap3-hello/index.html`                                                           | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/web/gap3-hello/src/animation.rs`                                                     | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/web/gap3-hello/src/main.rs`                                                          | Inherited Abird package/hosting/lab/product inventory | no               |
| `pkgs/web/gap3-hello/style.css`                                                            | Inherited Abird package/hosting/lab/product inventory | no               |

## Complete Pvl-only inventory

Preserved local desktop, hardware, tools and Pvl stack policy. No unrelated
target files were removed.

- `lib/audio.nix`
- `lib/desktop-base.nix`
- `lib/devices/asus-fa401wv.nix`
- `lib/devices/gmtek-evo-x2.nix`
- `lib/devices/lenovo-legion-5-15ach6h.nix`
- `lib/ext/gnome-ext/p7-borders.nix`
- `lib/ext/gnome-ext/p7-cmds.nix`
- `lib/ext/gnome-ext/sources.nix`
- `lib/ext/gnome-ext/update.sh`
- `lib/ext/handbrake.nix`
- `lib/ext/neovim-plugins/default.nix`
- `lib/ext/neovim-plugins/sources.nix`
- `lib/ext/neovim-plugins/update.sh`
- `lib/flatpak.nix`
- `lib/gdm-rdp.nix`
- `lib/gdm.nix`
- `lib/gnome.nix`
- `lib/gpg.nix`
- `lib/hardware/logitech.nix`
- `lib/hardware/mt7921e.nix`
- `lib/hardware/openrgb.nix`
- `lib/hardware/tpm.nix`
- `lib/images/gap3-base.nix`
- `lib/images/incus-base.nix`
- `lib/keyd.nix`
- `lib/mdns.nix`
- `lib/network-wifi.nix`
- `lib/printing.nix`
- `lib/profiles/all.nix`
- `lib/profiles/core.nix`
- `lib/profiles/desktop-core.nix`
- `lib/profiles/desktop-gnome-minimal.nix`
- `lib/profiles/desktop-gnome.nix`
- `lib/seatd.nix`
- `lib/stacks/pvl-dev.nix`
- `lib/stacks/pvl-registry.nix`
- `lib/stacks/pvl.nix`
- `lib/wm.nix`
- `pkgs/tools/codex-wrapper/codex-wrapper.sh`
- `pkgs/tools/codex-wrapper/default.nix`
