# Architecture review and cross-lineage convergence

## Scope and handoff

- Z main is pushed at `7a4bf7303`. Its normal pre-push hook passed without added
  limits: 15 concrete host configurations at nine-way concurrency, plus
  changed-package checks. Published aliases without a `hosts/` directory are
  outside the hook's host-selection set.
- Signed formatter-only commit `7a4bf7303` corrected 78 Markdown files already
  in the migration diff; the three shared README fixes also reached Nix.
  Unrelated historical files were not formatted.
- Nix main (`~/src/nix`) owns the complete convergence payload, integrated onto
  `115accd1a` for one signed aggregate commit. Dotlink v0.17.9 and the newer
  voice-profile changes are preserved; only `flake.nix` overlapped, with exactly
  three migration path/API replacements.
- All 863 source paths transferred exactly before scoped formatting and receipt
  updates. Shared `ab/` matches Z in bytes, types, full permissions and link
  targets: 573 files, six symlinks, 259 directories; Git tree
  `d5bf0fbf4cb09afcb1ce515b2369f1355f2e283c`.
- Nix main passed 37 focused checks, 526 changed-Nix static checks and `pvl-x2`
  derivation evaluation; seven hosts and 112 checks remain. Native evidence is
  reused only for byte-identical implementation/test/build files.
- Retire `worktrees/ab-convergence` after signed-commit preservation and final
  clean-host evaluation. Only generated Cargo/Ruff caches remain outside Git;
  keep the review branch. No Nix push, deployment, system build or VM run.
- Current evidence: manifest `nixMainIntegration`; earlier receipts are
  historical.

## Pre-integration handoff (historical)

- Z main: `~/spaces/abird/src/z`, branch `master`. The refinement implementation
  is committed in the four signed units below; documentation closeout
  accompanies this receipt.
- Nix review: `~/src/nix/worktrees/ab-convergence`, branch
  `review/ab-convergence` at `df659590b`. Migration, refinements and the latest
  shared Rust follow-up remain staged and uncommitted.
- Original signed Z migration `015f35857` (parent `327868dde`, tree
  `6af67e88a83e9df94e86ff903a5b9cb978ab5a4c`) was rebased to `fc1a40ee6` atop
  `b19f5eeb0`. All 54 incoming commits are retained; no manual conflicts.
- Earlier review tree `6c3faa11a5280e52337ffb308f5d22b50159e700` was transferred
  exactly into Z main before removing `worktrees/architecture-convergence`; its
  branch remains. That transfer receipt predates the rebase and commits.
- Nix main's pre-existing Dotlink update was committed concurrently as
  `673d750c5`, outside this task. Its tree exactly matches the initial staged
  content; it was preserved, not reset. Nix review remains based on `df659590b`;
  reconcile the newer main input update before integration.
- No push, deployment, NixOS system build or VM run. Only Z was committed by
  this task.

## Commit and follow-up sync (historical)

- `8707466cc` — fix(ab): unify package scopes and dependencies.
- `0226ed5f0` — fix(stack): preserve owned assembly namespaces.
- `9268c6511` — fix(services): make adapters extractable.
- `84a47066a` — feat(system): separate modules from repo policy.
- Every code unit passed focused checks before committing; all 35 Z acceptance
  checks then passed on the signed committed code snapshot. Existing Z native
  formatter/linter/test evidence is reused: implementation bytes did not change.
- Shared `ab/` was already current and needed no edits. Direct byte comparisons,
  exact path/type inventories, full permissions and symlink targets agree: **573
  files, 6 symlinks, 259 directories**; Git tree
  `ec0e1f08321102bea6c3afc853b43fd545d9b0f2`.
- Ported two incoming shared units to Nix, preserving original provenance:
  - `f85f48e99236dca1460c830f88fa937575969782`, 2026-11-18 20:49:54Z:
    stable-health confirmation after settling, with deadline regressions.
  - `b3050ec787a22547d9687ffa2077dc5770ec9ef0`, 2026-11-18 21:06:43Z: hold the
    replaced Git-profile inode open in its regression test.
- Only four host-manager Rust files changed at the destination. Exact source
  additions/removals were verified; Nix's independent build-receipt and bounded
  output tests remain intact. Private products, host policy and their plans/docs
  were excluded; destination inputs and manifests were not copied from Z.
- Nix: 37 focused checks, `pvl-x2` derivation evaluation and canonical
  `abird-host-manager` formatting/lint/tests passed. Cargo and test concurrency
  were limited to two; no live fleet operation ran.
- The Nix host derivation changed after the intended native-source update;
  repository policy/input files did not change. Clean Z commits also set
  `system.configurationRevision`, so earlier dirty-tree derivation IDs are
  historical, not post-commit identity guarantees.
- Phase evidence: manifest `commitSync`. Earlier phase receipts retain their
  original baselines, verification scopes and deployment limits.

## Findings and corrections

- **P1 — extraction:** four exported APIs imported sibling `core` by filesystem
  path: host-agent NixOS adapter, config family, fabric projection and phase
  projection. Independently copied components failed. Inject already-bound
  helpers; exercise the actual APIs from separate store copies.
- **P2 — boundary guard:** the lexical check missed `import ../../core;` and
  omitted `system`. Cover terminating punctuation and all component owners;
  exclude integration-test sources, not production imports.
- **P2 — installer:** an explicit unknown profile silently selected fallback
  behavior. Reject invalid selections while preserving absent-map/null fallback.
- **P2 — package overrides:** `withDeps` callers dropped explicit dependency
  injection, including host-manager source-only mode. Keep defaults declared
  once in constructor parameters; pass overrides through `withDeps`.
- **P2 — prebuilt stacks:** registry and family-builder results disagreed on
  placement/connector namespaces. Both now expose `topology.placements` and
  `network.externalConnectors`.
- **P2 — policy ownership:** shared GC coordination contained Z throughput
  settings. Move tuning to each repository: Z `1/12/8`, Nix `16/0/16` for jobs,
  cores and HTTP connections. Generic cache defaults are injectable; preserve
  destination cache ordering without forced overrides.
- **Inherited Rust defects:** the isolated-workspace `projectDir` rejection was
  an unforced binding; immutable store-root workspaces tried to enumerate their
  parent `/nix/store`. Force the guard and use single-path metadata inspection.
  Regression coverage retains source-symlink rejection.

## Port ledger

- Keep the six component owners and the `pkgs` / bound `ab` / deployment `stack`
  boundaries. No replacement framework or legacy helper-API facade.
- Initial convergence verified 566 regular files and 6 symlinks with identical
  bytes, kinds, modes and targets. This is historical evidence: subsequent
  refinements are now synchronized; current identity is recorded below.
- Converge the entire `ab/` tree, not selected files. Keep deployment identity,
  inputs, manifests, overlays and product membership outside it.
- Reverse-port opt-in
  desktop/audio/GDM/GNOME/Flatpak/keyd/printing/seatd/power/WM, Wi-Fi/mDNS/GPG,
  hardware/device profiles and Kache mechanisms.
- Initial convergence fixed Nvidia factory binding. Both trees now use a native
  module with `hardware.nvidia.package` overrides; Nix retains its custom driver
  selection in repository policy.
- Extract Nginx phase-route rendering into `ab/services/nginx/phase-routes.nix`;
  inject the stack projection function instead of importing a host or sibling.
- Preserve optional patched-Cargo qualification under Nix-owned
  `nix/tests/qualification/rust/pvl/`. Generic VM support accepts extra source
  inputs; production Cargo stays unchanged.
- Adapt destination Incus, tunnel, Nginx, installer, package and test callers.
  Keep runtime-relative fixture paths distinct from Nix import paths.
- Retain the published `lib-flake-configuration-family` check name at the
  destination repository boundary alongside the new canonical name.

## Design refinement

- Keep six component owners and three public contexts; no new framework.
- One scope implementation backs core/repository/child/dependency/Rust package
  binding. `core.packageScope` is the composition seam; leaves keep a core-only
  context. The default child path reuses its existing bound scope.
- `withDeps`: resolve paths only; preserve derivations (even with a `path`
  attribute), explicit values, supported `null` and unused-value laziness.
- Rust exports rebind the shared dependency resolver to the contextual build
  scope. A recording regression reproduced stale original-context resolution;
  both sibling build policy and injected context now survive `withDeps`.
- Shared uniqueness validation rejects package/alias/tool/app and cross-role
  service collisions. Explicit package and same-role service overrides remain.
- Ready-to-import WM/Nvidia modules; explicit `profiles.mkWmModule` for custom
  devices. Driver selection uses the native NixOS package option.
- Each repository owns Nix trust/cache defaults, unfree policy, Nix version, GC
  and state version. Shared Nix setup consumes one resolved policy.
  Representative-host policy was captured before edits for exact comparison
  afterward.
- Remove unused services runtime arguments. Keep normal bound usage named `ab`;
  use `abLib` only when both APIs are actually used in the same scope. Retain
  public API and boundary tests without freezing private helper filenames.
- One stack finalizer owns namespace joins and placement attachment; reject
  projection collisions and preserve role-remapping behavior.
- New package and stack regressions failed against the previous implementation
  before passing with the fixes. Exact final validation is recorded in the
  manifest's `zRefinement` section.
- Original Z gates: 35 focused checks, 41 changed Nix paths
  parsed/formatted/linted, scoped canonical format/lint, and documentation
  checks. The representative host retains the exact pre-refinement policy and
  toplevel derivation.
- Root output names retain all 50 packages, 20 apps, 21 modules and 34 hosts;
  all 150 existing checks remain, with two new contract checks.
- Introduced in Z first; subsequently synchronized into the Nix review worktree
  with destination-specific policy retained.

## Refinement sync and Z integration (historical)

- Shared `ab/`: **573 regular files, 6 symlinks, 259 directories including the
  root**; exact paths, bytes, kinds, full modes and symlink targets match. Git
  tree: `ec0e1f08321102bea6c3afc853b43fd545d9b0f2`.
- Nix's local file/directory permissions follow Z main's restrictive modes;
  permissions were only reduced. Git executable bits and code are unchanged.
- Port scope/package/dependency helpers, contextual Rust resolution, declaration
  collision guards, native module APIs, policy separation and stack
  finalization.
- Keep Nix cache/key ordering (including `cache.numtide.com`), custom Nvidia
  selection, WM device policy, `16/0/16` builder limits and state versions.
  Adapt WM customization to `profiles.mkWmModule`; policy regression tests
  assert exact cache/key order and evaluated GC/state/unfree settings.
- **37 Nix checks and 35 Z-main checks passed.** The 36 changed destination Nix
  files passed formatting, parsing, Statix and Deadnix. Scoped canonical format
  and lint passed in both worktrees for `hello-python`.
- `pvl-x2` retains exact equality across 30 selected active feature/policy
  groups. Both `pvl-x2` and `gap3-rivendell` retain their prior toplevel
  derivations.
- No removed Nix public names: 26 packages, 11 apps, 2 shells, 7 hosts, 3 image
  groups and 10 modules. All 110 prior checks remain; two new contracts bring
  the total to 112.
- Current fingerprints, check names and preservation evidence are in the
  manifest's `sharedAb` and `refinementSync` sections. `initialSharedAb` and the
  earlier qualification sections remain historical receipts.

## Initial convergence verification

- Original Z migration: 12 architecture/extraction and 12 integration checks
  passed; four additional isolated probes still reproduced the extraction bug.
- Corrected Z worktree: 17 focused regression checks and the `gap3-rivendell`
  toplevel derivation evaluation passed.
- Destination: 33 distinct focused checks passed across component extraction,
  optional features, package parity, Rust toolchains/layering, repository
  policy, Incus, Podman, fabric/phase projection and placement/fold integration.
- Destination public surface: no removed names. Preserved 26 packages, 11 apps,
  2 shells, 7 hosts, 3 image groups, 10 modules and all 103 prior checks; now
  110 checks.
- `pvl-x2`: toplevel derivation evaluation and exact equality with the committed
  baseline across 30 selected feature/policy groups, including package/service
  inventories, GPU settings, firewall ports, caches/order and build concurrency.
- Stock and patched-Cargo qualification recipes evaluate against immutable
  public snapshots. Both retain all baseline/changed-source controls and
  distinct build identities; neither changes the production default.
- Static sweep: 868 Nix paths parsed and passed Statix/Deadnix. Only the public
  Rust forwarding implementation used Deadnix's `--no-lambda-pattern-names`;
  forwarded constructor parameters remain published, with binding checks intact.
- Complete check names and shared-tree fingerprints:
  [verification manifest](architecture-convergence-checks.json).
- Canonical scoped commands passed in both worktrees:
  `nix fmt -- --project hello-python` and
  `nix run .#lint -- --diff --base HEAD --project hello-python`.
- Validation uses `--no-write-lock-file`, IFD disabled and bounded test builds
  (`--max-jobs 1 --cores 2`). Test derivations, including the host-agent
  dependency of the Podman checks, were built; no NixOS system was built.

## Limits

- Risk-focused review, not exhaustive runtime/fleet certification. Full
  `nix flake check`, full-repository lint, VM qualification, installer
  boot/install and deployment were not run.
- Public image-group names were checked, not a broad installer/host evaluation.
- Historical staged Markdown whitespace outside this work was not rewritten.
- Nix-main integration still requires approval; retain its independently
  committed input update.
- The representative Nix host has Nvidia disabled; module override tests do not
  constitute qualification on active Nvidia hardware.
