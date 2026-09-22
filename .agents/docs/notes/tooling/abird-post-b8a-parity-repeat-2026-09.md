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

## Current shared parity

The comparison uses Pvl `ea272d31` and frozen Abird `28631f93`, plus the live
phase 1 worktree candidates, for all tracked common paths under `lib/**`,
`pkgs/**`, and `scripts/**`.

| Scope        |  Common | Exact bytes/mode | Explained differences | Mode differences | Abird-only | Pvl-only |
| ------------ | ------: | ---------------: | --------------------: | ---------------: | ---------: | -------: |
| `lib/**`     |     237 |              227 |                    10 |                0 |         21 |       41 |
| `pkgs/**`    |     278 |              273 |                     5 |                0 |        283 |        3 |
| `scripts/**` |      20 |               20 |                     0 |                0 |          2 |        0 |
| **Total**    | **535** |          **520** |                **15** |            **0** |    **306** |   **44** |

Exact-set SHA-256 over sorted `path<TAB>mode<TAB>blob` rows without a trailing
newline: `ffb6fdeff31bb1297ae01cdd8e832617805cea4b7e7b9d40f575ff03072e73d6`.

The 15 remaining common differences are fully explained:

| Group                      | Count | Paths and ownership                                                                                                                                                                                                                                                               |
| -------------------------- | ----: | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Pvl platform policy        |     8 | `lib/ext/nvidia/sources.nix`, `lib/hardware.nix`, `lib/installer/config/default.nix`, `lib/locale.nix`, `lib/network.nix`, `lib/nix.nix`, `lib/sudo.nix`, and `lib/systemd.nix`: NVIDIA rollback plus physical-host, installer, locale, DNS/cache, privilege, and suspend policy. |
| Repository identity        |     2 | `lib/flake/repo-checks.nix` and `lib/stacks/default.nix`: repository-owned test and stack composition.                                                                                                                                                                            |
| Package identity           |     4 | `pkgs/README.md`, both Cloudflare app READMEs, and `pkgs/manifest.nix`: repository package inventory, organization examples, secret placement, and export graph.                                                                                                                  |
| Shareable structural seams |     1 | `pkgs/support/nats-streams/default.nix`: generic core mixed with Abird consumers, secrets, and routes.                                                                                                                                                                            |

The 306 Abird-only paths remain product, stack, lab, service, mail-operation,
and repository-identity surfaces. The 44 Pvl-only paths remain physical desktop,
hardware, profile, Pvl stack/identity, Codex wrapper, and Pvl Nixbot identity
surfaces. No mode drift exists.

## Convergence sequence

The next convergence work should reduce differences by separating shared
mechanisms from repository policy rather than copying one repository's topology
into the other.

1. Completed: move Abird's Rust-parity ledger assertion into an Abird identity
   test sibling.
2. Completed: make Abird's Incus LXC machine profile explicit and remove Pvl's
   stale commented kernel parameters with evaluated behavior unchanged.
3. Keep `pkgs/support/nats-streams/default.nix` as a parameterized shared core.
   Move Abird's Chat Intelligence streams, HTTP bridge, secrets, and routes into
   an Abird-owned wrapper or consumer module.
4. Completed: keep the host-manager README generic and move repository topology
   facts into repository-owned notes and examples.
5. Add a Pvl-owned platform-policy module and move physical firmware, GeoClue,
   Cloudflare DNS, sudo timeout, and suspend throttling into it. Preserve
   evaluated behavior while making the neutral shared base files byte-identical.
6. Inject repository-local Nix cache endpoints from repository composition
   instead of embedding them in `lib/nix.nix`; keep the common cache/key policy
   canonical. Installer configuration remains topology-owned.

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
