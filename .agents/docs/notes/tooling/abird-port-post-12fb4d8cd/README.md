# Abird → PVL port through `3f363a062`

**Candidate against PVL `016e4679c`.** Compared the configured `abird` remote’s
committed `refs/heads/master`, `3f363a0628fb497ff27ffc8e778cf73d9ade882b`, not
its working tree or feature branches. A repeat fetch returned the same tip. No
remaining shared forward-port candidate was identified at that cutoff. This is a
source port and parity audit, not a deployment receipt.

- [Per-commit ledger](commits.md): 67 newly inspected SHAs: **9 clean, 7
  adopted, 51 skipped**. Four of the 16 applicable changes were already present
  in PVL; 12 contributed changes to this candidate. The ledger starts before the
  previous port and links both of its chapters. Two rewritten website commits
  account for the difference between **288 historically reviewed SHAs** and
  **286 on today’s DAG**.
- [Path-level divergences](divergence.tsv): all **871** exceptions across `ab/`,
  `lib/`, `pkgs/` and `scripts/`, with both Git modes, both object IDs where
  applicable, and a disposition. The directory is `pkgs/`, not `pkg/`.

## Logical units and integration decisions

| Source decision                                | Candidate change                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| ---------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `baff28483`, Nov 26                            | GIMP MCP `0.6.0`, tagged upstream source, no local FastMCP patch. The overlay uses the locked unstable Python `mcp_1`; Pi keeps `gimp-mcp-server`. Use the matching user-installed plugin.                                                                                                                                                                                                                                                                                                   |
| `4b57692d6`, Nov 26                            | MCPVault `0.18.4`; the generated npm lock covers the published app and closure. The package asserts version agreement. The updater builds a staged set before installing manifest, lock and pin. Existing overlay name and positional vault argument survive.                                                                                                                                                                                                                                |
| `f482db6de`, Nov 26                            | Document the ownership boundary behind both moves, including the package catalog and desktop instructions. A generated lock is pin data; a downstream-maintained patch or lock is a different ownership boundary.                                                                                                                                                                                                                                                                            |
| `037b20f30`, `c49d5bdb7`, Nov 27               | Kache release updater, checksum verification and atomic pin replacement, then `2.1.1 → 2.4.0` for both Linux architectures. No cache-policy, daemon or topology change.                                                                                                                                                                                                                                                                                                                      |
| `ba0088db3`, `a5b532eca`, Nov 27               | Independently bump Computer Use Linux `0.7.35 → 0.7.64` (all six asset hashes) and MCP for Blender `2.2.6 → 2.3.3` (sdist and reporting revision).                                                                                                                                                                                                                                                                                                                                           |
| `885fb96f1`, Nov 27                            | NVIDIA production R620 `620.70.06 → 620.73.04`, including driver, open module, settings and persistenced hashes. Preserve driver track and rollback policy.                                                                                                                                                                                                                                                                                                                                  |
| `3ad5af88e`, `271d9798c`, `d81bdc30f`, Nov 27  | Portable Rust test timing: wait for progress, match operation deadlines, release gates on drop and assert the intended outcome. No private controller fixtures or helper references.                                                                                                                                                                                                                                                                                                         |
| `080443a4c`, Nov 27                            | Match the common Git block: each master/main push needs fresh approval. The monorepo block still requires explicit instructions before any commit; repository-specific MIT framing stays local.                                                                                                                                                                                                                                                                                              |
| `fc1a40ee6`, Nov 21 (historical ledger row 95) | **Older partial port completed:** both services implementations and their direct leaf tests were already here. The missing tests required the exported `kanidmPackage`/`cliPackage` arguments and called both script constructors with a caller-supplied package. Put these probes in the existing extracted-services check; do not import the Abird product/host acceptance suite. `53eb54739` relocated the original checks; `f11dbc8d1` was later isolation work, not their introduction. |

The two MCP moves are intentionally **breaking for root flake callers**:
`.#gimp-mcp` and `.#mcpvault` disappear. Their consumers use
`nixosConfigurations.<host>.pkgs.{gimp-mcp,mcpvault}`, now documented and
verified. No host, user, flake input, secret, image deployment or root workspace
membership was changed to match Abird.

## Byte and mode audit

| Root       | Exact / same-path | Different | PVL only | Abird only |
| ---------- | ----------------: | --------: | -------: | ---------: |
| `ab/`      |         581 / 581 |         0 |        0 |          0 |
| `lib/`     |         112 / 120 |         8 |       52 |         42 |
| `pkgs/`    |         501 / 505 |         4 |        2 |        755 |
| `scripts/` |           30 / 30 |         0 |        0 |          8 |
| **Total**  | **1,224 / 1,236** |    **12** |   **54** |    **805** |

Compared the union of paths in the final source tree and candidate index,
including modes and symlink targets. Independently checked working bytes against
the index and checked for untracked nonignored paths in these roots. The
protected encrypted test fixture was verified by identical base/index/source
object and mode and unchanged filesystem size and nanosecond mtime; it was not
opened. No common mode/type discrepancies. Before porting, against the same
final source, there were 17 differing common paths, 61 PVL-only and 813
Abird-only.

- `ab/` has the identical tree object
  `695cf25ba45cc70f2b6a47725c4049b684ad993b`. The complete host-manager and
  host-agent package trees also match (`582eb7f1d`, `fe6816b72`).
- `lib/ext/`: **75/76 common files exact**, 12 PVL-only, **zero Abird-only**.
  All six ported units match their upstream trees. The one different pin is
  Stalwart CLI; PVL has `2.0.0`, Abird still targets `1.0.14`. No downgrade or
  reverse port.
- All 30 PVL scripts match. Abird has eight more: its ACME, desktop
  publishing/forwarding, mail and update-policy procedures/tests. PVL-only
  packages are two Codex wrapper files. Abird-only packages include the
  controller family, product sites, Uauth, Cloud Run tools and previously
  declined optional products/examples. A matching package name does not make an
  unselected product’s host tests portable.
- Identity-named test paths count as one-sided, even when byte-identical under
  `pvl/` versus `abird/`. PVL now tests the two exported service constructors in
  `external-services.nix`; Abird tests them in `component-boundaries.nix`.

### Every same-path exception

| Path                                                     | Why it differs                                                                                       |
| -------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `lib/ext/stalwart-cli/sources.nix`                       | Retain the newer PVL version and four platform hashes.                                               |
| `lib/overlays/default.nix`                               | Desktop/voice inputs, ordering and local package selection. The agent-tools overlay itself is exact. |
| `lib/overlays/unstable.nix`                              | PVL desktop vs Abird server selections.                                                              |
| `lib/profiles/policy/locale.nix`                         | PVL geolocation/resume handling vs fixed Abird timezone.                                             |
| `lib/profiles/policy/network.nix`                        | Local DNS-over-TLS, resolver and DNSSEC defaults.                                                    |
| `lib/profiles/policy/nix-builder.nix`                    | Jobs/cores/HTTP connections: PVL `16/0/16`, Abird `1/12/8`.                                          |
| `lib/repo-checks.nix`                                    | Distinct product, stack and repository check registrations.                                          |
| `lib/tests/repository/nginx-phase-projection-routes.nix` | Same logging contract; PVL exercises the portable renderer, Abird its proxy-host adapter.            |
| `pkgs/manifest.nix`                                      | Actual package membership; both MCP entries removed, not replaced with private products.             |
| `pkgs/README.md`                                         | Local catalog, build examples and migration guidance.                                                |
| `pkgs/cloudflare-apps/README.md`                         | PVL’s encrypted Terraform input channel.                                                             |
| `pkgs/cloudflare-apps/llmug-hello/README.md`             | Repository-specific Worker declaration; package constructor matches.                                 |

## Receiver history from before the previous session

The
[previous receipt](../abird-port-post-39c711a7a/README.md#receiver-history-from-before-the-preceding-port)
lists every receiver commit from `fb1db04a2` through the last port and its
audit. From its working base `bed576ed7` through the current base, the full
receiver sequence is:

| PVL         | What landed / relevance today                                                                                       |
| ----------- | ------------------------------------------------------------------------------------------------------------------- |
| `9136b4feb` | Last port: signed cache relay.                                                                                      |
| `5b45b770c` | Last port: CLI owns terminal progress.                                                                              |
| `f0a4c2b3f` | Last port: repository-independent component fixture isolation.                                                      |
| `c9e263871` | Last port: service package composition guidance.                                                                    |
| `9d2c3b4e9` | Last port: GitHub token precedence.                                                                                 |
| `e3734fd70` | Last receipt and exception inventory through the pre-rewrite website pair.                                          |
| `102e2284a` | Already contained the Nov 26 source and flake updates in `4ae1c43a8`.                                               |
| `088b33ff3` | Already contained the two final lock entries in `c1b254766`; preserve the other PVL inputs.                         |
| `ef8658e82` | Pi pins match `12ef8a822`.                                                                                          |
| `522c02dcc` | Prism pin matches `12ef8a822`; PVL’s image selections cover `749458108`.                                            |
| `71acdb36d` | Local Paperless Valkey `9.2.1`; unrelated to Abird’s Garage/Grafana image updates.                                  |
| `016e4679c` | Local Prism listener/container-port correction. Keep it; matching an image tag is not reason to undo a runtime fix. |

## Verification and limits

- Built the registered `pvl-external-services`, `lib-kanidm-normalization`,
  `lib-stalwart-cli`, `lib-hardware-nvidia`, `lib-llama-router-module` and
  `lib-prism-llama-cpp-package` checks offline with IFD disabled. The
  extracted-services check also rejected four negative controls (optional
  arguments or failing constructors).
- Evaluated the five tool derivations against `pvl-a1`’s locked package set and
  `pvl-l5`’s selected NVIDIA driver (`620.73.04`). Verified root MCP shortcuts
  were removed. In isolated Home Manager evaluation (synthetic public cache
  inputs, no private material), `pvl-a1` retains both MCP commands; `pvl-vlab`
  has only MCPVault of this pair, with the same positional vault argument. No
  user vault or desktop was accessed.
- Updater tests: **14** discovery, **6** generic reporting and **8** NVIDIA
  tests passed. Kache explicit-version report/no-op and bad second-architecture
  checksum rollback passed. MCPVault lock-version mismatch was rejected;
  report/no-op and injected failed final build left files unchanged and cleaned
  staging. These are offline tests, not claims of a real registry update.
- Realized Kache `2.4.0` and ran Clang 21.1.8 via its packaged shim in an
  isolated, networkless cache. Cold compile: one compiler run. After deleting
  the 1,024-byte object: one local hit, no compiler run, identical SHA-256,
  linked executable exited 0. Only the disposable daemon was stopped.
- Changed Nix passed Alejandra, Statix and deadnix. Updater scripts passed shfmt
  and ShellCheck; changed Markdown/JSON passed formatter checks. No fleet run,
  NixOS build, deployment, or fleet-wide lint/evaluation. The four changed
  MCP/desktop tools evaluated; their combined realization plan with Kache needed
  303.5 MiB of substitution downloads, so no new MCP binaries or GUI sessions
  were qualified here. GIMP’s plugin requires 3.2+ and reinstallation after a
  server update; the existing default desktop package is 3.0.8, the locked
  unstable option 3.2.8. NVIDIA evaluation is not a boot, suspend, CDI or GPU
  workload test.
