# Abird → PVL: follow-up after `39c711a7a`

**Integrated on PVL `master`.** PVL base
`bed576ed7317e91789808c0f153a704e9834f806`. Final source: the configured `abird`
remote's committed `refs/heads/master` at
`12fb4d8cdc8e2d9630ebdd122370ede2df65488c`, not its worktree or the candidate
described in its reverse-port notes. No remaining forward-port candidate in this
range.

- [Source ledger](commits.md): **221 unique source commits across two
  sessions**, starting at `46c3b6298` exclusive. The
  [first 174](../abird-port-2026-11-25/commits.md) and
  [next 47](commits.md#175199) are disjoint and together exhaust
  `git rev-list 46c3b6298..12fb4d8cd`. Of the 47 new commits: **11 clean, 8
  adopted, 28 skipped**. Five needed changes here; fourteen already had their
  applicable units. The first fetch found 45; a repeat found the two product
  sites at the end, then the advertised tip was unchanged.
- [Path-by-path exceptions](divergence.tsv): **867 rows**, each with PVL/Abird
  mode and object ID where present, and the reason for the difference. Counts
  use `pkgs/`; there is no `pkg/` directory.

## What needed porting

| Source                            | Unit                           | Candidate                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| --------------------------------- | ------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `d31d1d138` (Nov 25)              | Signed-cache owner relay       | Exact manager code/tests and README. Both the target and workstation can lack the route to a cache. Only a classified final cache connectivity error can change the route; keep the declared publisher, URL, destination and trust checks. Explicit modes, TLS, signature, missing-object and SSH failures do not authorize an owner fallback. Map the generic rollout guidance onto the PVL incident note; omit the private edge bootstrap. |
| `e7cb470ae` (Nov 25)              | CLI terminal ownership         | Exact code/tests and UX note. Ordinary library reporters don't paint stderr; a heartbeat cannot retain an abandoned reporter. The actual CLI still installs terminal cleanup.                                                                                                                                                                                                                                                                |
| `f11dbc8d1` (Nov 25)              | Component owner-test isolation | Extend the registered PVL gate to catch repository or absolute checkout imports in owner tests. Only Nix sources enter the scan; the independent consumer fixtures continue to exclude owner tests. No second copy of Abird's test registry.                                                                                                                                                                                                 |
| `5e3b9fcc3`, `ff2afe894` (Nov 25) | Shared operator guidance       | Converge the generic services guide and the updater authentication note. Keep both repositories' actual package selection, examples and NVIDIA rollback policy. No package or credential changes.                                                                                                                                                                                                                                            |

No wholesale package replacement: the complete PVL manager **before** this port
was exactly the parent tree of `d31d1d138`
(`08162f25ae6021950789f5b78d023ddf2c961950`). Applied the two manager patches in
source order, then compared the complete result, including the new executable
test. No changes to `ab/`, public cache roots, package pins, flake locks or
topology were necessary.

## Byte and mode audit

| Root       |    Exact / common | Different | PVL only | Abird only |
| ---------- | ----------------: | --------: | -------: | ---------: |
| `ab/`      |         581 / 581 |         0 |        0 |          0 |
| `lib/`     |         104 / 112 |         8 |       52 |         63 |
| `pkgs/`    |         508 / 512 |         4 |        2 |        730 |
| `scripts/` |           30 / 30 |         0 |        0 |          8 |
| **Total**  | **1,223 / 1,235** |    **12** |   **54** |    **801** |

Compared the union of all Git paths at the source tip and candidate index,
including executable modes, types and literal symlink targets. Independently
verified PVL working bytes against staged blob IDs and checked for nonignored
untracked paths in the four roots. For the protected encrypted fixture, used
identical base/index/source object and mode plus unchanged worktree size and
nanosecond mtime, without opening it. No common mode/type mismatches. Before
porting, the same final source had 23 different common files and two additional
source-only manager files.

- **`ab/`:** identical Git tree `695cf25ba45cc70f2b6a47725c4049b684ad993b`,
  including six symlinks. No exceptions.
- **Packages:** manager **175/175**
  (`582eb7f1da6bebc4fd792c2d23baea2ebf26200e`), host-agent **155/155**, Nixbot
  **11/11** common files exact. Nixbot also has three Abird-only acceptance
  files. The only PVL-only package files implement the personal Codex wrapper.
  Abird-only packages include its controller/protocol/UI, the two product sites
  (218 files), services, and previously declined optional packages without a PVL
  consumer.
- **`lib/ext/`:** **67/68** common files exact; 12 PVL-only and 10 Abird-only.
  The sole common mismatch is Stalwart CLI: keep PVL **2.0.0**, versus
  **1.0.14** in the actual `12fb4d8cd` blob. Consider a reverse port if Abird
  wants the CLI upgrade; do not downgrade PVL to match a stale pin.
- **`scripts/`:** all 30 PVL paths match, including exporter, exporter
  regressions, and update/recovery scripts. The eight Abird-only files are its
  ACME, desktop publishing/forwarding, mail and package-selection test files.

### All 12 same-path differences

| Path                                                     | Reason to retain it                                                           |
| -------------------------------------------------------- | ----------------------------------------------------------------------------- |
| `lib/ext/stalwart-cli/sources.nix`                       | Newer PVL release and its four platform hashes.                               |
| `lib/overlays/default.nix`                               | Local overlay order and desktop/voice packages vs. Abird product inputs.      |
| `lib/overlays/unstable.nix`                              | Desktop vs. server package selections.                                        |
| `lib/profiles/policy/locale.nix`                         | PVL geolocation/resume handling vs. fixed Abird timezone.                     |
| `lib/profiles/policy/network.nix`                        | PVL resolver, DNS-over-TLS and DNSSEC defaults.                               |
| `lib/profiles/policy/nix-builder.nix`                    | Jobs/cores/HTTP connections: PVL `16/0/16`, Abird `1/12/8`.                   |
| `lib/repo-checks.nix`                                    | Local check names, product/stack membership and registrations.                |
| `lib/tests/repository/nginx-phase-projection-routes.nix` | Same logging assertions, portable renderer vs. Abird proxy-host adapter.      |
| `pkgs/README.md`                                         | Repository package catalog.                                                   |
| `pkgs/manifest.nix`                                      | Actual product membership; do not register the imported websites.             |
| `pkgs/cloudflare-apps/README.md`                         | PVL's encrypted Terraform input channel; both resolve paths from the project. |
| `pkgs/cloudflare-apps/llmug-hello/README.md`             | Worker declaration channels differ; package constructor itself matches.       |

Identity-mapped `lib/tests/repository/{pvl,abird}/` files count as one-sided at
their raw paths. The TSV identifies exact mapped fixtures separately from
adapted ones; it does not give either credit as a same-path match. PVL's
desktop/physical integrations and Abird's product/stack tests are not portable
modules simply because they live in `lib/`.

## Receiver history, from before the preceding port

The source ledger above gives per-source dispositions. For orientation, these
are **all PVL commits** from the preceding port base `fb1db04a2` through the
current candidate base, oldest first. Do not count reverse ports of the same
behavior as new PVL work.

| PVL         | Unit landed                                                                              |
| ----------- | ---------------------------------------------------------------------------------------- |
| `bf5b1aa5c` | Bounded health-failure diagnostics.                                                      |
| `8bd220d7e` | Terraform progress by project.                                                           |
| `a65a5f533` | Prepare lock across repository re-exec.                                                  |
| `af8637f46` | Per-proxy access logging and regression.                                                 |
| `accebbea1` | Noninteractive GitHub token fallback.                                                    |
| `030d0a0c7` | Reject incomplete explicit NVIDIA requests.                                              |
| `c9881496a` | Validate the staged Pi update against pinned Nixpkgs.                                    |
| `28e528d29` | Bound Tailscale Go/toolchain and vendor-hash probe.                                      |
| `85cb564cf` | Inject the Pi package set.                                                               |
| `c50b3ced6` | Atomically publish export ciphertext.                                                    |
| `b4bbe1acf` | Use the declared Cloudflare assets derivation.                                           |
| `21f1dbc09` | Correct migrated callers and fixtures.                                                   |
| `e56c2cf4e` | Register the local external consumer gates.                                              |
| `8023e013b` | Reconcile component and operator guidance.                                               |
| `65e7f420a` | Preceding comprehensive source ledger and parity audit.                                  |
| `366c835df` | Clarify tmux plugin pin ownership; source `6cf55431e` predates even the preceding range. |
| `850c43ff3` | Acquire missing Compose/Quadlet images before drain.                                     |
| `e310c0fcc` | Podman acquisition progress.                                                             |
| `b96505a5e` | AI model prefetch progress.                                                              |
| `2de213ec4` | Fleet Acquire current activity.                                                          |
| `831313cfc` | Pool acquisition across deployment waves.                                                |
| `dca2b0f0f` | Retire repo product qualification scenarios.                                             |
| `bed576ed7` | Align Rust qualification guidance and links.                                             |

This follow-up adds `9136b4feb` (cache relay), `5b45b770c` (progress output),
`f0a4c2b3f` (component tests), `c9e263871` (service guidance) and `9d2c3b4e9`
(updater authentication). The shared trees in `9d2c3b4e9` match the audited
candidate.

## Verification and limits

- `nix fmt -- --project abird-host-manager` and
  `nix run .#lint -- --project abird-host-manager` passed: format, Clippy,
  **1,194 tests passed, 3 ignored, 0 failed** (excluding nested libtest
  invocations). The package formatter left the manager bytes unchanged.
- Ran `pkgs/tools/abird-host-manager/tests/cache-relay-smoke.sh` in its isolated
  network/PID namespaces and temporary Nix stores. Real OpenSSH and HTTP(S):
  trusted copy verified; untrusted signature and a stopped relay both rejected.
  No operator host or cache contacted. `bash -n` and ShellCheck passed.
  Standalone `shfmt -d` suggests whitespace changes to the smoke script; `pkgs/`
  is package-managed, not part of the root shfmt gate. Kept the passing upstream
  fixture byte-exact.
- Realized `.#checks.x86_64-linux.pvl-component-boundaries` with IFD disabled.
  The owner-test scan included 74 Nix files across the six components. Replayed
  the realized scan with isolated good/bad fixtures: a local fixture passed, a
  repository-relative import failed, and a missing search root failed rather
  than being treated as a clean scan.
- Candidate verification did not run an all-host evaluation, fleet operation,
  complete NixOS build, deployment or reverse port. The prior receipt's
  Terraform argument-only prebuild caller and lazy sibling-component dependency
  findings are shared limitations, not missing commits resolved by this port.
