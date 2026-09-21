# Abird post-`1b64de24` shared port, 2026-09-22

## Authority and frozen boundaries

The target started clean at Pvl `908f8b7813584eefd55a939cef73d5298ee0dbba` on
`master`, equal to `origin/master`. The previous port froze Abird at
`1b64de2437f73fe3d7463d349ef8d0da400ef397`. This audit fetched and froze
configured `abird/master` at `b8a766ed66c4026474ecf65df9c3b6f99faba5f2`: 33
linear commits.

Implementation was staged in `worktrees/abird-post-1b64-port-20260922` on
`agent/abird-post-1b64-port-20260922` before promotion to `master`. No push,
deployment, service restart, image pull, database query, or migration was
performed. Secret-key files were neither listed nor read.

## Logical units ported

### Rust fleet parity

Source `b859c121` is byte/mode exact for 12 shared host-manager files:
`src/{bin/nixbot.rs,main.rs}`,
`src/fleet/{deploy,environment,host_runtime,native}.rs`, and
`tests/{fleet_binary,fleet_contract,fleet_deploy,fleet_environment,fleet_host_runtime,fleet_native_runtime}.rs`.
It adds current-generation admission, GitHub-token projection into Nix, real
build effects during dry deploys, and pre-switch admission classification. Pvl's
workflow already used `--control-plane-first`. The source-only Python test
reading Abird's `.agents/plans/**/TEST-DISPOSITION.md` is excluded; Pvl has no
such ledger. Bash remains the active Nixbot engine.

### PostgreSQL extension policy

Source `799a778d` is byte/mode exact for
`lib/services/postgres-extensions/{runner.py,tests/test_runner.py}` and new
`lib/services/postgres/extensions.nix`. The runner accepts target-only policies,
refuses downgrades, supports optional ordered `upgradeFrom`, and retains legacy
`sources` compatibility. The Nix helper derives image, PostgreSQL major, and
TimescaleDB target from one image tag.

The Abird fixture is adapted into `lib/flake/tests/pvl/postgres-extensions.nix`
and registered through Pvl's identity aggregator. Source `2a1fa45d` is not
applied to the Pvl host: Pvl does not consume the runner, and a real policy
requires reviewed target versions for its `pg18.6-ts2.30.1` image. No migration
policy is claimed or executed.

### Inline image-update holds

Source `4a6ccfb9` is byte/mode exact for the external-source design pattern,
`lib/podman-compose/{default.nix,tests/module.nix}`, and
`scripts/support/{podman-image-updater.py,tests/test_podman_image_updater.py}`.
Structured `{ ref; hold; }` images render only `ref`, remain report-visible, and
are excluded from edits. Conflicting held/automatic uses fail closed. Abird's
Graphiti consumer is excluded because Pvl has none.

### Remote-build resilience

Source `558d1e64` is byte/mode exact for the builder module/test, Rust
`fleet/build.rs` and its two tests, and Bash `nixbot.sh`. The builder defaults
`http-connections = 8`; Rust and Bash remote realization use `--fallback`; and
Bash captures stdout outside command substitution so interrupts reach the
supervised build. The Python test keeps the runtime regression but omits the
Abird plan-ledger assertion. Pvl durable notes are adapted.

## Every source commit after the prior port

Status: **ported** is an exact shared unit; **adapted** combines exact shared
files with Pvl integration/exclusions; **adopted** predates this session;
**skipped** contributes no Pvl change.

|  # | Commit     | Subject                                                                | Status  | Disposition                                                                                                           |
| -: | ---------- | ---------------------------------------------------------------------- | ------- | --------------------------------------------------------------------------------------------------------------------- |
|  1 | `39dd2d5e` | refactor(test): split shared test areas into repository identity homes | adopted | Pvl `cca6266f` already carries exact generic files and the Pvl identity home; Abird identity files stay source-owned. |
|  2 | `0585a314` | feat(ai): add llama.cpp router backend on abird-srv                    | adopted | Shared llama-router arrived via Pvl `61cb0f2b`; Abird host/registry wiring excluded.                                  |
|  3 | `363eb0b6` | feat(ai): adopt shared services.ai catalog and backend module          | adopted | Pvl `8159ed0d`; later Pvl backend/storage work advances it.                                                           |
|  4 | `dc7e5026` | llama-router: load-lazy reconcile, poll presets (byte-sync)            | adopted | Pvl `4d22e08e`; source host note excluded.                                                                            |
|  5 | `91d4b104` | docs(llama-router): laptop models-max raised to 2                      | adopted | Pvl host/record landed as `93539ffc`; Abird note excluded.                                                            |
|  6 | `6da34b1b` | feat(agent): add managed encrypted backups                             | skipped | Abird Agent, protocol, web, and product-plan ownership.                                                               |
|  7 | `95e7de21` | docs(plan): accept 3.7c memory store                                   | skipped | Abird product planning only.                                                                                          |
|  8 | `ac468b45` | feat(ai): reconcile model ownership                                    | adopted | Pvl `af016242`; shared ownership implementation present.                                                              |
|  9 | `0579269d` | refactor(ai): derive backend deployment                                | adopted | Pvl host projection `fa82d647`; Abird host file excluded.                                                             |
| 10 | `b1ed967c` | docs(ai): close model ownership plan                                   | skipped | Abird lifecycle history.                                                                                              |
| 11 | `971b794a` | fix(ai): harden model reconciliation                                   | adopted | Pvl `e0ac3e37`; core reconciler exact.                                                                                |
| 12 | `8a6a708e` | feat(memory): add governed store                                       | skipped | Abird Agent/protocol/web memory product.                                                                              |
| 13 | `b1b8599e` | docs(memory): accept phase 3.7d                                        | skipped | Abird product planning.                                                                                               |
| 14 | `b9162883` | docs(platform): define application architecture                        | skipped | Abird architecture/plan history; no shared implementation.                                                            |
| 15 | `84776c11` | docs(plan): define state storage architecture                          | skipped | Abird design plan.                                                                                                    |
| 16 | `b859c121` | fix(nixbot): restore Rust deployment parity                            | adapted | Twelve Rust files exact; workflow already equivalent; Abird ledger test/history excluded.                             |
| 17 | `058ff50e` | fix(update): match exact image references                              | adopted | Exact Pvl `086ad4ef`.                                                                                                 |
| 18 | `e5c485d8` | feat(images): compare terminal version tags                            | adopted | Exact Pvl `ace73f74`.                                                                                                 |
| 19 | `44eb5bea` | build: refresh dependencies                                            | adopted | Pi/VS Code sources exact; later Pvl lock refresh supersedes matching nodes while retaining its graph.                 |
| 20 | `4d59bc35` | docs(agent): record forward state reset                                | skipped | Abird plan/event history.                                                                                             |
| 21 | `46c4690a` | revert(memory): withhold 3.7c runtime                                  | skipped | Absent Abird product runtime.                                                                                         |
| 22 | `83304642` | build(opendesign): update to 0.23.0                                    | skipped | Established absent Pvl package/consumer.                                                                              |
| 23 | `799a778d` | refactor(postgres): simplify extension policies                        | adapted | Three shared files exact; fixture adapted to Pvl identity.                                                            |
| 24 | `2a1fa45d` | refactor(postgres): localize extension releases                        | skipped | Abird/Gap3 consumers only; no reviewed Pvl migration policy.                                                          |
| 25 | `0f551391` | perf(ci): raise Gondor CPU limit                                       | skipped | Gap3 Gondor capacity policy.                                                                                          |
| 26 | `8897efc2` | docs(memory): transition 3.7d to 3.7e                                  | skipped | Abird product planning.                                                                                               |
| 27 | `a932eb53` | build(abird): refresh service images                                   | skipped | Abird host pins/identity.                                                                                             |
| 28 | `7f06049c` | build(gap3): refresh service images                                    | skipped | Gap3 host pins.                                                                                                       |
| 29 | `4a6ccfb9` | feat(images): add inline update holds                                  | ported  | Five generic module/updater/test/design files exact.                                                                  |
| 30 | `25e9b03a` | fix(graphiti): hold coupled image updates                              | skipped | Abird Graphiti consumer only.                                                                                         |
| 31 | `2b31d018` | feat(opendesign): add managed AI default                               | skipped | Established absent OpenDesign package/consumer.                                                                       |
| 32 | `558d1e64` | fix(nixbot): harden remote builds                                      | adapted | Six shared files exact; Python test and Pvl notes adapted.                                                            |
| 33 | `b8a766ed` | style(docs): apply deno formatting                                     | skipped | Source-local documents only; Pvl docs formatted independently.                                                        |

Totals: 11 adopted, four newly ported/adapted, and 18 skipped with explicit
ownership reasons. No unexplained source commit remains.

## Final byte and mode parity

The audit compares frozen source blobs/modes with live worktree bytes, including
new files.

| Scope        | Common | Exact bytes/mode | Explained differences | Mode differences | Source-only | Pvl-only |
| ------------ | -----: | ---------------: | --------------------: | ---------------: | ----------: | -------: |
| `lib/**`     |    237 |              215 |                    22 |                0 |          21 |       41 |
| `pkgs/**`    |    278 |              271 |                     7 |                0 |         282 |        3 |
| `scripts/**` |     20 |               20 |                     0 |                0 |           2 |        0 |
| Total        |    535 |              506 |                    29 |                0 |         305 |       44 |

Exact-set SHA-256 over sorted `path<TAB>mode<TAB>blob` rows without a trailing
newline: `4eeb6c52a8581777ae0fde7926c79b7ca449f151efda8e61feb0b6edcaaf5932`.

All 29 common differences are explained:

| Group                           | Count | Paths and ownership                                                                                                                                                                                                                                              |
| ------------------------------- | ----: | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Established Pvl platform policy |    11 | `lib/ext/nvidia/sources.nix`, `lib/{hardware,images/default,kernel,locale,network,nix,stacks/default,sudo,systemd}.nix`, and `lib/installer/config/default.nix`: NVIDIA rollback plus physical-host, installer, DNS/cache, stack, privilege, and suspend policy. |
| Repository identity             |     1 | `lib/flake/repo-checks.nix`: Pvl identity versus Abird product/topology promotion.                                                                                                                                                                               |
| Pvl-ahead AI                    |     9 | Five `lib/services/ai/**` files and two test files each under llama-router and Ollama: backend configuration, storage hierarchy, and separated ports. Preserve and reverse-port later.                                                                           |
| Pvl-ahead nginx                 |     1 | `lib/services/nginx/compose/compose.yaml`: Pvl 1.30.5 versus Abird 1.30.4.                                                                                                                                                                                       |
| Package surface                 |     6 | `pkgs/README.md`, two Cloudflare app READMEs, `pkgs/manifest.nix`, `pkgs/support/nats-streams/default.nix`, and host-manager README.                                                                                                                             |
| Adapted shared test             |     1 | `pkgs/tools/nixbot/tests/test_nixbot.py`: runtime regressions retained; Abird plan-ledger assertion excluded. Pvl topology remains in `test_nixbot_pvl.py`.                                                                                                      |

The 21 source-only library paths are Abird identity/topology after adding the
shared PostgreSQL helper. The 282 source-only package paths remain Abird
products, bots, labs, and applications. The two source-only scripts are Abird
mail operations. Pvl-only paths remain desktop/hardware/profile packages, Pvl
identity checks, and its Nixbot sibling test.

No unexplained relevant shared gap remains. Remaining shared-area drift is
Pvl-ahead behavior or a source repository-specific plan assertion and should not
be overwritten merely to reduce the difference count.

## Validation

- 70 direct Python tests pass: 18 PostgreSQL runner and 52 image-updater tests.
  The inherited PostgreSQL subprocess cases require the repository-local `tmp/`
  staging directory; validation created it first and removed it afterward.
  Neither frozen source nor Pvl currently registers that runner suite as a flake
  check, so this remains an explicit direct-only gate.
- 273 Nixbot discovery tests pass, including Pvl identity and the new interrupt
  regression.
- `cargo test -p abird-host-manager -- --test-threads=1` passes.
- Source hashes prove every intended exact file equals frozen Abird; all common
  modes match.
- Six affected Nix checks build: host-manager, Nixbot, builder GC coordination,
  Podman Compose module, image updater, and the Pvl PostgreSQL identity check.
- `cargo fmt --check` and Clippy over all host-manager targets with warnings
  denied pass.
- Repository-wide no-IFD diff lint passes against the exact pre-port base on all
  four flake systems and all seven changed NixOS hosts.
- Markdown formatting and `git diff --check` pass.
