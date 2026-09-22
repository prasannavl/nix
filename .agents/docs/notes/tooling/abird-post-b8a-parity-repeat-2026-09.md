# Abird post-`b8a766ed` parity repeat, 2026-09-22

## Frozen boundary

The previous Pvl audit froze Abird at
`b8a766ed66c4026474ecf65df9c3b6f99faba5f2`. This repeat fetched the configured
`abird` remote and froze `abird/master` at
`28631f93bb660758f170164b61ac08b20c9838fa`: seven linear commits. The Pvl target
started clean at `ea272d312ace8c802cbce067728039ecdd901d3c`, five local commits
ahead of `origin/master`.

The reciprocal audit and phase 1 convergence were developed in
`worktrees/abird-post-b8a-parity-20260922` on
`agent/abird-post-b8a-parity-20260922`. The initial seven-commit window required
no shared implementation port; phase 1 then converged four shared boundaries.
The reviewed units were committed on primary `master` and published. No
deployment, service restart, image pull, database query, or migration was
performed. Secret-key files were neither listed nor read.

## Every source commit

|  # | Commit     | Subject                                     | Status  | Disposition                                                                                                                                                                |
| -: | ---------- | ------------------------------------------- | ------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
|  1 | `b427d72b` | `test(ai): separate backend port ranges`    | adopted | Reverse-port of the five generic test files from Pvl `4a6b3315`; scoped patch, blobs, and modes are exact.                                                                 |
|  2 | `aa76042a` | `feat(ai): add backend model configs`       | adopted | Reverse-port of the catalog, default module, and library test from Pvl `eebeac7d`; scoped patch, blobs, and modes are exact.                                               |
|  3 | `0a09a296` | `fix(ai): own model storage hierarchy`      | adopted | Reverse-port of the AI module and combined module test from Pvl `b8a8944f`; scoped patch, blobs, and modes are exact.                                                      |
|  4 | `657ebb59` | `chore(images): refresh nginx pin`          | adopted | Reverse-port of the shared nginx `1.30.5` pin from Pvl `108257cf`; scoped patch, blob, and mode are exact.                                                                 |
|  5 | `5ec70a19` | `docs(parity): record Pvl shared port`      | skipped | Abird-owned reverse-port ledger, plan, queue link, work capsule, events, and indexes. Durable parity evidence is adapted here; source workflow history stays source-owned. |
|  6 | `04e81373` | `style(docs): format parity record`         | skipped | Formatting only for the Abird-owned plan files introduced by the preceding commit.                                                                                         |
|  7 | `28631f93` | `docs(parity): archive completed Pvl audit` | skipped | Abird-owned publication evidence and plan archival; no shared implementation or parity count changes.                                                                      |

Totals: four commits were already adopted exactly and three source-local
documentation commits were skipped. No unexplained source commit or portable
implementation gap remains in this window.

## Exact reverse-port verification

All ten implementation paths changed by the four reverse-port commits are byte-
and mode-identical between Pvl `ea272d31` and Abird `28631f93`:

- `lib/services/ai/{catalog,default,module}.nix`
- `lib/services/ai/tests/{lib,module}.nix`
- `lib/services/llama-router/tests/{module.nix,test_helper.py}`
- `lib/services/ollama/tests/{module.nix,test_helper.py}`
- `lib/services/nginx/compose/compose.yaml`

Each mode is `100644`. Independent scoped patch-ID comparisons also map the four
source commits back to their originating Pvl units.

## Phase 1 convergence

Phase 1 completed roadmap items 1, 2, and 4 as three independently reviewed
logical units:

1. Abird's Rust parity-ledger assertion moved from the shared
   `pkgs/tools/nixbot/tests/test_nixbot.py` into the Abird-only sibling
   `test_nixbot_abird.py`. Both repositories retain 272 identical shared runtime
   tests and one repository identity test. Abird's full 273-test discovery and
   its 273-entry ledger check still pass.
2. Abird now names `machineProfiles.incusLxc` explicitly for its Incus LXC
   image. The evaluated profile, container setting, kernel parameters, and
   toplevel derivation are unchanged. Pvl's obsolete commented kernel-parameter
   block was removed with no Nix syntax-tree change.
3. The host-manager README now documents only the portable contract. Pvl and
   Abird controller, placement, route, and example identities moved into each
   repository's existing host-manager note.

The four formerly divergent common files are now byte- and mode-identical:

- `lib/images/default.nix`
- `lib/kernel.nix`
- `pkgs/tools/abird-host-manager/README.md`
- `pkgs/tools/nixbot/tests/test_nixbot.py`

## Phase 2 cache endpoint convergence

Roadmap item 6 was completed directly in Pvl's primary worktree and in the Abird
side worktree `worktrees/shared-parity-phase2-cache-20260922`. Each repository
continues to own its endpoint once in `hosts/nixbot.nix` at
`config.registries.nix.url`. Its root `flake.nix` passes the complete inventory
`registries` attrset as `repoRegistry`; the shared `lib/flake/root.nix` projects
the `nix` entry and injects only that normalized registry record through
`specialArgs`; and the now byte-identical `lib/nix.nix` prepends its `url` to
the common community caches. Future registry types can receive their own
root-level projections.

The common trust catalog is canonicalized as Abird, Pvl, nix-community, then
Numtide. This changes only the displayed order of Pvl's first two trusted keys;
the trusted key set is unchanged. All seven Pvl hosts retain their exact
substituter URL list, all 32 Abird hosts retain their exact URL and key lists,
and both repositories' Incus LXC and VM base images receive their own inventory
endpoint. Installer images remain unchanged and do not import `lib/nix.nix`.
Direct profile evaluation without repository composition continues to work and
uses only the common caches.

## Phase 3 NATS structural convergence

Roadmap item 3 leaves `pkgs/support/nats-streams/default.nix` as the
byte-identical generic package and stream-set factory. Both manifests select
that default. Abird's `chat-intelligence.nix` is now a Gap3-only NixOS adapter
over the factory; it owns the stream inventory, HTTP bridge routes,
managed-secret assertions, delivery policy, and unit ordering without replacing
the generic package export.

The wider repository-module mechanism replaces `extraCommonModules` with one
validated named registry. Repository modules load everywhere; stack adapters
load only for the exact canonical `stackName`; null and aggregate evaluations
receive repository modules only. Pvl registers `abird-host-agent` repository-
wide, while Abird registers the Chat Intelligence adapter only under `gap3`.
Composition-time factories use `repoModulePkgs`, derived from the selected flake
profile's nixpkgs and overlays, to avoid forcing config-derived `pkgs` during
static module collection.

Roadmap item 5 was explicitly skipped at human review. Pvl keeps hardware,
GeoClue, Cloudflare DNS, sudo timeout, and suspend throttling directly in its
current shared-path modules; no `platform-policy` abstraction is introduced.
Those five files remain intentional policy differences.

## Current shared parity

The comparison uses published phase 1 Pvl `7073da89` and Abird `181c69f3`, plus
the phase 2 and 3 task paths, for all tracked common paths under `lib/**`,
`pkgs/**`, and `scripts/**`. Seven later Pvl AI/runtime commits advanced the
primary worktree during this phase; they are outside this frozen parity window
and are not silently classified or ported here.

| Scope        |  Common | Exact bytes/mode | Explained differences | Mode differences | Abird-only | Pvl-only |
| ------------ | ------: | ---------------: | --------------------: | ---------------: | ---------: | -------: |
| `lib/**`     |     240 |              230 |                    10 |                0 |         21 |       41 |
| `pkgs/**`    |     278 |              274 |                     4 |                0 |        284 |        3 |
| `scripts/**` |      20 |               20 |                     0 |                0 |          2 |        0 |
| **Total**    | **538** |          **524** |                **14** |            **0** |    **307** |   **44** |

Exact-set SHA-256 over sorted `path<TAB>mode<TAB>blob` rows without a trailing
newline: `1851bdf7f51895472fea84b2e5581f3ef75acfd23c5cb7c4cf8ec3468443c6c1`.

The 14 remaining common differences are fully explained:

| Group               | Count | Paths and ownership                                                                                                                                                                                                                                            |
| ------------------- | ----: | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Pvl platform policy |     7 | `lib/ext/nvidia/sources.nix`, `lib/hardware.nix`, `lib/installer/config/default.nix`, `lib/locale.nix`, `lib/network.nix`, `lib/sudo.nix`, and `lib/systemd.nix`: Pvl compatibility, physical-host, installer, locale, network, privilege, and suspend policy. |
| Repository identity |     3 | `lib/flake/repo-checks.nix`, `lib/stacks/default.nix`, and `lib/stacks/modules.nix`: repository-owned tests, stack data, and module registrations.                                                                                                             |
| Package identity    |     4 | `pkgs/README.md`, both Cloudflare app READMEs, and `pkgs/manifest.nix`: repository package inventory, organization examples, secret placement, and export graph.                                                                                               |

The 307 Abird-only paths remain product, stack, lab, service, mail-operation,
and repository-identity surfaces. The 44 Pvl-only paths remain physical desktop,
hardware, profile, Pvl stack/identity, Codex wrapper, and Pvl Nixbot identity
surfaces. No mode drift exists.

## Convergence sequence

The roadmap resolved shared mechanisms separately from repository policy rather
than copying one repository's topology into the other.

1. Completed: move Abird's Rust-parity ledger assertion into an Abird identity
   test sibling.
2. Completed: make Abird's Incus LXC machine profile explicit and remove Pvl's
   stale commented kernel parameters with evaluated behavior unchanged.
3. Completed: keep `pkgs/support/nats-streams/default.nix` as a generic shared
   factory and register Abird's Chat Intelligence streams, HTTP bridge, secrets,
   and routes through a Gap3-only repository adapter.
4. Completed: keep the host-manager README generic and move repository topology
   facts into repository-owned notes and examples.
5. Skipped at human review: keep Pvl firmware, GeoClue, Cloudflare DNS, sudo
   timeout, and suspend throttling in the current shared-path modules; do not
   introduce a `platform-policy` abstraction.
6. Completed: inject each inventory-owned Nix cache endpoint from repository
   composition and keep the common cache/key policy canonical in byte-identical
   shared modules. Installer configuration remains topology-owned.

Do not chase parity for the NVIDIA version pin, repository check/stack
composition, package manifest, or repository-specific README and secret-path
examples unless their underlying policy first converges. Those differences are
evidence of explicit ownership rather than missed ports.

## Validation

- The configured source was fetched and frozen before comparison.
- Every new implementation blob and mode was checked directly against the frozen
  source.
- Three independent audits covered the seven-commit window, `lib/**`, and
  `pkgs/**` plus `scripts/**`.
- The phase 1 Nixbot suite, image evaluation, Nix parsing, package README token
  scan, targeted formatting, and Markdown lint pass.
- Repository-wide no-IFD diff lint, targeted Markdown formatting/lint, and
  `git diff --check` pass.
- Phase 2 no-IFD evaluation groups all 7 Pvl hosts and all 32 Abird hosts by
  identical cache settings within their repository; reusable Incus image
  evaluation and the direct profile test also pass.
- The shared `repoRegistry` seam fixture retains both `nix` and `containers`
  entries, while the consumer test receives only the projected Nix record. It
  preserves that record's `host` and `url` and keeps missing-registry evaluation
  compatible.
- Both repositories' no-IFD diff lint widens the shared-root change to every
  affected host and root output and passes.
- `lib/nix.nix` and `lib/flake/root.nix` have identical bytes and mode `100644`
  across the two live candidates.
- The generic NATS seam check and both repository identity checks build. Abird's
  package output, bridge config path, service options, credentials, unit
  ordering, and delivery settings are exact to `181c69f3`.
- The repository-module selector rejects malformed registries, missing paths,
  duplicate names or paths, unknown stacks, malformed runtime stacks, and an
  `all` specialization; two independent NATS stream sets evaluate together
  without specialization leakage.
- Gap3 exposes the Chat Intelligence option, while Abird Nest and Gondor do not.
  The host-bound stream package derivation, generated bridge configuration,
  service credentials, and both complete systemd unit projections are exact to
  the clean `181c69f3` base.

## Publication

The phase 1 units landed on primary `master` as `6e9f32bb`
(`refactor(kernel): remove stale parameters`), `2fc6cf93`
(`docs(host-manager): separate topology`), and `bb5df99e`
(`docs(parity): record phase one convergence`). All commits are signed.

The first pre-push gate exposed a hook-environment bug rather than a source
failure: Git's repository-selection variables leaked into Rust tests that build
temporary fixture repositories, so three fixture commits were written into the
disposable staging branch. The same targeted test binary passed outside the
hook. Publication retained the authoritative hook but invoked it through a
one-use wrapper that cleared only `GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE`,
and `GIT_COMMON_DIR`. The staging tree was disposable; primary `master` and the
unrelated dirty main-worktree note were unaffected.
