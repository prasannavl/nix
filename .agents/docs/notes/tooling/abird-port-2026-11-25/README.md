# Abird → PVL port, 2026-11-25

PVL baseline `fb1db04a206b736bf999039d433afb1c24acd4ac`. Source is the
**committed master of the configured `abird` remote**,
`39c711a7adeb945a11a6a6bcbf5962db466d3223`, not its working directory or the
snapshot named in its reverse-port note. No host deployments, upstream changes
or destination commits.

- [Every source commit, with disposition and rationale](commits.md):
  `46c3b6298..39c711a7a`. **174 unique commits: 13 clean, 24 adopted, 137
  skipped.** Of the 37 clean/adopted, 18 were already present and 19 received
  work this pass. The full DAG has two merge commits; a first-parent walk would
  report only 141 entries. Some newly reachable side-branch commits predate the
  previous port by author date.
- [Every different or one-sided path](divergence.tsv) under `ab/`, `lib/`,
  `pkgs/` and `scripts/`: destination and source Git modes, blob IDs and
  disposition. Package root is `pkgs/`, not `pkg/`.

## Start point: the preceding port session

The last exhaustive receipt on PVL was
[`c21c683be`](../abird-port-2026-11-followup/tail-port-2026-11-17b.md), covering
`f20876d35..46c3b6298` from PVL `2f100c51c`. Subsequent layout convergence
(`7d6630622`, `01dfd31df`) proved specific units, not that all intervening
source commits were accounted for. The five source commits of that preceding
session are reproduced here so there is no gap at the boundary:

| Source      | Previous disposition | PVL result                                                                                                          |
| ----------- | -------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `73b479bc3` | Adopted              | `99c8da080`: NVIDIA branch metadata, lookup and updater; retained local rollback history.                           |
| `456a86f60` | Skipped              | Forgejo 17.0.1 host pin/incident note; no equivalent PVL Forgejo deployment.                                        |
| `3b754962e` | Skipped              | Abird Zulip app/broker/cache upgrade; PVL runs its own versioned deployment.                                        |
| `7da7965d5` | Adopted              | `d4cfe0c24`: exact Tailscale Go selection, input, overlay, pins and documentation; preserved the other local locks. |
| `46c3b6298` | Adopted              | `f3b67c712`: Go/Fenix cache trust and tests, with the PVL Numtide cache retained.                                   |

Receiver sequence of that session: `99c8da080`, `f3b67c712`, `d4cfe0c24`,
`c21c683be` (receipt). The new ledger starts **after** its last source SHA.
Earlier receipts and their ledgers are linked from
[the preceding audit index](../abird-port-2026-11-followup/README.md).

## Logical port units

| Unit                                    | Source                                                                 | What changed here                                                                                                                                                                                                                                                                      |
| --------------------------------------- | ---------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Unsettled health diagnosis              | `532d3a1c6`                                                            | Bounded recent diagnostics distinguish failures from transitional state; no change to the readiness deadline.                                                                                                                                                                          |
| Prepare locking and visibility          | `404921179`, `9a6450211`                                               | Hold prepare exclusion across repository re-exec, preserve activation handoff/workspace lifetime, show source and time spent waiting. Keep PVL launch receipts and activation observation.                                                                                             |
| Terraform progress                      | `493d3c721`                                                            | Per-project steps, phase outcomes and timings; no Terraform state or project selection changes.                                                                                                                                                                                        |
| Ingress logging                         | `bfdc440a1`                                                            | Both portable files match source. Test opt-out and inherited logging without adopting Corp routing or credentials.                                                                                                                                                                     |
| Source discovery and release updates    | `4bd062caa`, `b69f296a1`, `99e83aded`, `d3d902ba9`                     | GitHub fallback that does not prompt or trace tokens; NVIDIA automatic/explicit missing-release contracts; Pi hash probe and validation use the staged candidate with locked Nixpkgs. Keep the current release pins.                                                                   |
| Toolchains and package composition      | `d4628d057`, `6dbc57741`, `05fb02f6d`                                  | Complete the Tailscale resolver and vendor-hash path, inject the package set in Pi leaves, use the declared Cloudflare assets derivation, and document the current APIs.                                                                                                               |
| Repository relocation and qualification | `520e6b1b5`, `fc1a40ee6` through `84a47066a`, `53eb54739`, `b42649fd4` | Correct migrated caller paths and child-ref fixture; register missing consumer checks at the destination boundary. Test identity **selection**, not just binding; retain local cache roots and remove redundant assertions. Refresh active guides, not historical deployment receipts. |

The reverse-port subjects at the end of the window are not missing PVL changes.
Kache/oyo/diffx, the pgAdmin patch, the NVIDIA pin, build receipts and pending
user-job telemetry originated here. All ten common direct flake locks match by
input name and complete locked record. Bladebro, Pi, tuicr and VS Code source
files match. Do not replace either repository’s input graph.

## Final parity

| Tree       |    Exact / common | Different | PVL only | Abird only |
| ---------- | ----------------: | --------: | -------: | ---------: |
| `ab/`      |         578 / 579 |         1 |        0 |          0 |
| `lib/`     |          99 / 117 |        18 |       55 |         62 |
| `pkgs/`    |         505 / 510 |         5 |        2 |        512 |
| `scripts/` |           27 / 29 |         2 |        1 |          8 |
| **Total**  | **1,209 / 1,235** |    **26** |   **58** |    **582** |

Compared the union of Git paths and new nonignored files, hashing working bytes
(literal targets for symlinks) and checking Git type/executable mode. For the
protected Tailscale test fixture, used the unchanged index object, mode and stat
metadata without reading its contents. No common mode/type mismatch. The
pre-port baseline had 1,177 exact and 58 different common paths; the final
manifest has 666 exception rows. An identity-mapped test is still one-sided in
the raw same-path count.

- **`ab/`:** The only difference is `ab/services/nginx/compose/compose.yaml`:
  keep PVL's newer `nginx:1.30.8` from `fb1db04a2`; Abird still pins `1.30.6`.
  All component code, fixtures and symlinks match. Full directory equality would
  require a downgrade here or an independent pin update there.
- **`lib/ext/`:** 65/68 exact. Keep Stalwart CLI `2.0.0` (despite the reverse
  receipt, Abird's actual blob pins `1.0.14`), tuicr's native test dependencies
  (`git`, `ps`), and the working Tailscale vendor-hash probe. Abird's probe
  calls an injected leaf without `ab`; PVL overrides the registered package
  instead. Pi and NVIDIA updater code/tests are exact.
- **Remaining `lib/`:** repository-specific overlays,
  locale/network/builder/cache policy, check registrations, optional
  patched-Cargo qualification, and PVL identity/renderer regressions. The
  external gates are mapped to the local check registry; identical fixture
  source is not counted as proof that an executable gate runs. Preserve both
  existing PVL image wrappers; the public image outputs use `lib/images.nix`.
- **`pkgs/`:** complete manager (173/173) and host-agent (155/155) trees match.
  Five common differences: package catalog/manifest, two Cloudflare READMEs
  documenting local input channels, and the Wrangler helper using its declared
  asset derivation rather than a nested build.
- **`scripts/`:** All common updater and migration/recovery scripts match. The
  exporter and its help differ by design: PVL uses split Terraform projects, not
  the exporter's legacy categorized schema. It now refuses that layout
  **before** credential resolution or API access. On a supported layout it
  requires explicit recipients and atomically publishes fresh ciphertext,
  without writing plaintext, accepting stale output or pruning old exports. No
  live Cloudflare access or schema migration was performed.
- **One-sided packages:** Most Abird-only entries are its product,
  infrastructure, service and acceptance trees. Not all are private: the
  PostgreSQL/SQLite queues, EDI example and optional LLM/search services were
  previously declined and still have no PVL selection. KiloCLI was explicitly
  removed in `47bb09380`. PVL-only entries include desktop/voice/editor policy,
  Codex wrapper, local qualifications and the exporter regression. The manifest
  lists them individually.

## Findings for coordinated work, not missing source commits

1. **Terraform app prebuild:** The native manager
   (`fleet/terraform.rs::apps_preparation_command`), Bash Nixbot and
   `tf/modules/cloudflare/scripts/worker-dir-nix-resolver.sh` can still pass an
   argument-only package constructor to `nix build --file`. This is present on
   **both** tips. The direct Wrangler helper is repaired; the other three
   callers need a coordinated contract for repo-bound vs standalone packages and
   the source revision of a recovery copy. Do not treat the static-asset build
   as proof these three operator paths work.
2. **Independent component extraction:** Eight portable checks now run here
   (core package, runtime, services, repo, stack, component boundaries, NixOS
   core and synthetic deployment). Passing them is not universal extraction
   proof: `stack.config.prebuiltFamily`, `stack.phase.routeProfiles`'
   invalid-service diagnostic, `repo.runtimeCloseouts` and host-agent
   admission/projection branches under `services.modules.abirdHostAgent` still
   assume a sibling `core/`. Adjacent vs physically separated source probes
   distinguished these from PVL drift. Do not change the public dependency
   contract in only one lineage.
3. **Reverse-port candidates:** Abird can independently consider the newer
   nginx/Stalwart pins, tuicr check dependencies, bound Tailscale probe,
   composed Wrangler assets and the synthetic selection/rendering and operator
   safeguards where applicable. Its stock-only qualification recipe also omits
   the `qualificationToolingSrc` argument passed by the shared VM wrapper; PVL's
   optional lane already accepts it. Static interface finding, not a VM run.
   None requires writing to the Abird remote for this port.

## Verification and limits

- Canonical manager lint (including format, Clippy and tests): **1,184 passed, 3
  ignored, 0 failed** with two build jobs. The standalone updater and Pi suites
  passed **164 + 17 tests**; five synthetic exporter tests passed. No invocation
  of a real update, Wrangler deployment, fleet action, DNS operation or
  Terraform state command.
- All eight new consumer/boundary checks realized under the pinned x86_64-linux
  flake. Identity selection, cache registry, NVIDIA and Pi updater check outputs
  also realized. Cloudflare static assets built;
  `pvl-x2.config.system.build.toplevel.drvPath` evaluated with IFD disabled,
  without building the system.
- The nginx route check's **Nix assertions evaluated**, including inherited
  logging and opt-out on the HTTP and TLS listeners. Its `nginx -t` build **did
  not run**: pinned tinycc bootstrap archive `cb41cbfe…` had a fixed-output hash
  mismatch before nginx could build. Left the lockfile and expected hash
  unchanged. Not a passing runtime check.
- Changed-file checks passed: Alejandra, Statix and Deadnix on 18 Nix files;
  shfmt and ShellCheck on six scripts; Deno and markdownlint on 37 Markdown
  files. The main-worktree parity manifest reproduced the isolated validation
  tree's manifest exactly. Its Git index is untouched; the new Nix test files
  must be included when staging the port for Git-backed flake checks.
- No full `nix flake check`, all-host lint/evaluation or cross-architecture
  qualification. Source is frozen by SHA; working changes do not assert
  deployment status.
