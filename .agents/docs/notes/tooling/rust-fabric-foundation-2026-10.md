# Rust fabric foundation — implementation checkpoint

## Authority and scope

Human `prasannavl` (resolved via `gh api user --jq .login`) authorized a new
implementation worktree, the producer-fidelity spike, and the toolchain
contract. The current repository toolchain remains the default. For
external/custom requirements prefer fenix when it works; retain oxalica support
for projects using it or needing its toolchains. Providers must remain easy to
switch. **Retain child-flake wrappers**, rather than retiring them into
generated mirrors. This supersedes the earlier oxalica-first and
wrapper-retirement recommendations.

Worktree: `worktrees/rust-fabric-foundation-20261001`, branch
`agent/rust-fabric-foundation-20261001`, based on `0711cc31`. The primary Pvl
and Abird trees are not modified. Selected uncommitted design context was copied
into the worktree; unrelated primary-tree edits were not. No commit,
publication, deployment, or expensive compilation was authorized by the original
checkpoint. The human subsequently authorized committing the prepared foundation
index and moving into next-phase preparation; publication/merge and expensive
compilation remain separately gated.

## Delivery boundary

This checkpoint implements the provider/toolchain foundation and retained
package-owned child-wrapper composition, plus a bounded producer feasibility
harness. It does not claim an exact producer, successful unit-DAG adoption, or
implementation of the entire multi-ecosystem fabric. Cargo remains
authoritative; incomplete capture must fail closed. A spike authorization is not
a producer-fidelity pass.

- Current nixpkgs Rust stays the default. Explicit provider inputs are lazy;
  selecting an unavailable provider is an error, not silent fallback.
- `craneLibFor` selects the capsule's compiler. All artifact-producing helpers
  must use the selected library, including shared bases and fan-in joins.
- The producer and executor must use the same resolved build contract.
- Retained child wrappers track the root's original refs for declared inputs:
  NixOS release branch and flake-utils ref, plus the Crane release tag only
  where needed for Rust builds. Lockfiles still record exact revisions. Rust
  wrappers inject Crane rather than falling back accidentally to `rustPlatform`;
  matching refs alone do not guarantee matching lock snapshots.
- Child wrappers call the generic `stack/package.nix` helper directly. Package
  definitions own intrinsic dependency defaults; there is no repository routing
  adapter or separate child registry. Manager's default agent constructor
  forwards `pkgHelper`; explicit dependency overrides and `null` source-only
  mode remain supported. Root manifest registrations no longer repeat those
  dependency defaults.
- `pkgsForSystem` allows retained wrappers to consume the parent's complete
  package set. Equal pins alone do not imply equal arbitrary overlays.
- These wrappers remain repository-bound compatibility entrypoints, not newly
  independent generated mirrors. G10 mirror generation remains future work.
- `pkg-helper.nix` now imports `rust-toolchain.nix`. Future mirror/extraction
  generators must include this new sibling in the helper import closure; the
  older Design M observation that the helper has no sibling imports describes
  the pre-foundation state.

## Validation and next gate

Cheap validation: pure provider tests, no-IFD direct module evaluation, child
manifest composition parity, wrapper pin drift checks, Python harness tests, and
offline stable Cargo capability probes. No real Cargo compilation is part of the
cheap phase.

The expensive gate still needs exact unit/host-target/feature/edge capture,
correct build-script handling, cross-capsule identical derivations, deliberate
feature/toolchain divergence, and fallback of only an unsupported capsule. If
stable capture is insufficient, do not disguise package metadata as an exact
unit graph; report the blocker and choose a producer extension or G4+M with the
human. G4's Abird 24-member cost gate remains mandatory.

## Initial checkpoint evidence

- 72 pure no-IFD toolchain assertions pass, covering provider selection, missing
  provider failures, mismatched artifact rejection, supplied-build producer
  identity, selected compiler tools, shared bases, joins, checks and isolated
  workspaces.
- Real no-IFD before/after helper comparison on the hello-rust pilot with the
  same source and package set preserves build, shared-base, member-layer and
  fmt/lint/test derivation paths.
- Real no-IFD child composition parity evaluation passes for registered retained
  wrappers with one identical injected package set. The evaluated check drv is
  `/nix/store/a4f6rdknwgv8na1jazvy8i4cyzf4k5kv-lib-flake-child-parity-test.drv`;
  it was not built. Arbitrary parent overlays are not automatically propagated
  by independent child input pins.
- 24 producer-harness Python tests and 3 pin-updater tests pass. All 13 retained
  wrapper pin checks pass.
- Cheap Abird probe: installed Cargo/rustc 1.95.0, 24 workspace package
  definitions, no resolve graph from `--no-deps`; manifest and lock hashes
  unchanged. Producer qualification remains false, decision `not_proven`.
- Stable `--unit-graph` is unavailable. Metadata and compiler-artifact messages
  alone do not prove exact host/target roles or typed unit edges. This is a
  capture gap, not a proven impossibility of a stable wrapper-based producer.
- Independent review found false supplied-build identity, custom cross-role,
  minimal-component and isolated-helper flag issues. They were fixed or
  explicitly fail-closed, with regression coverage. Follow-up review confirmed
  ABI-aware platform guards and preserved legacy oxalica toolchain files.
- Raw probe output was summarized here; successful temporary output is removed.
- Whole-root input evaluation exceeded its bounded timeout; no builds were
  attempted. Narrow validation used already-cached root nixpkgs/crane sources
  directly. Fenix/oxalica adapters are fixture-tested, not fetched or built.

Built-in contracts use `toolchainFile` (not `file`). Fenix toolchain-file
selection additionally requires an explicit manifest `sha256`; custom target and
component selections must be in that file or a pre-resolved immutable `resolved`
toolchain derivation. Fenix minimal profile selection adds matching
clippy/rustfmt components; a minimal toolchain file must explicitly include
both. Custom Nix cross package sets fail closed until Crane's spliced toolchain
contract is implemented. Native package sets with explicit Cargo target/std
selection remain a separate case. The legacy `mkCargoWorkspacePackage` helper
rejects custom toolchains until its distinct build/test flags can be translated
faithfully to Crane; ordinary `mkRustDerivation` isolated workspaces remain
supported. Supplied prebuilt packages carrying artifact layers must retain
verified matching producer identity; opaque supplied builds are not relabeled as
if compiled by the selected toolchain. Unsupported fields fail instead of
silently ignoring requested targets. Inputs/adapters can be injected without
changing package definitions. Retained child composition accepts
`rustToolchainInputs` and `rustToolchainProviders`, or `pkgsForSystem` for full
parent composition.

## Fresh review findings — historical, fixed below

A fresh independent three-lane review plus cheap reproductions found additional
issues. Earlier assertion counts remain valid, but are not sufficient evidence
that this checkpoint is ready for integration. No implementation fixes or new
build/provider authorization resulted from this review.

Confirmed with cached Crane and no IFD, without compilation:

- A later overlay overriding `pkgs.craneLib` is ignored by `craneLibFor null`,
  whose resolver captured the earlier `prev`. The effective caller and selected
  fmt derivation paths differ. Separately, direct pre-overridden Crane libraries
  contribute compiler identity but not the tools returned by `toolPkgs`.
- `buildAttrs.env.RUSTC` can select compiler B while the package and member
  layer are certified with toolchain A's identity. Reject or reconcile
  compiler-changing overrides before certifying artifacts, including Trunk
  builds.
- Native caller `pkgs` plus a custom toolchain and cross `buildAttrs.stdenv`
  produces an aarch64 Cargo target without triggering custom-cross rejection.
  Validate the effective Crane stdenv/selector, not only caller package
  platforms.

Confirmed with disposable synthetic fixtures under checkout `tmp/`:

- Hardlinking `report.json` to an inspected lock causes report publication to
  overwrite that lock after its unchanged check; the report still claims
  `lock_unchanged = true`. Use atomic replacement of a fresh report file and
  reject input/output inode aliases.
- A successful probe can leave a background descendant alive. Exception and
  interrupt exits also lack process-group cleanup. Enforce lifecycle cleanup on
  every exit path, not only timeout/output overflow. The reproduction's dummy
  descendant was explicitly killed.
- Descriptor results share nested mutable input values: later input mutation
  changes the descriptor without updating its recorded hash. Snapshot inputs
  before normalization/hashing; this remains a synthetic-schema issue, not an
  assertion about a qualified producer.

Additional static review findings:

- Reused output directories retain unreported Cargo-home configuration and
  target/runtime state. Own fresh exclusive per-run writable directories.
- Path-based child matching selects the first canonical registration if several
  variants use one file. Require an explicit package ID or reject ambiguity.
- `pkgsForSystem` silently ignores simultaneously supplied overlays/provider
  customization. Define mutually exclusive modes or an explicit extension rule.
- Pin discovery recognizes only the literal `).mkFlakeOutputs`; harmless
  formatting/refactoring can skip a wrapper and still report success. Use a
  fail-closed retained-wrapper inventory.
- Unexpected JSON `reason` types can raise `TypeError` before an incomplete
  evidence report is published. Validate protocol shapes.

Design recommendation, not a newly accepted decision: resolve one coherent
compiler/library/tools/identity contract at the composition boundary; keep
repository package lookup optional/injected rather than mandatory in generic
child helpers. Extend tests with actual wrapper outputs and cached-Crane
override cases. Existing injected-package-set parity tests intentionally do not
validate actual wrapper default construction or Crane forwarding. Provider
builds and producer qualification remain untested. Successful synthetic fixtures
were removed; no implementation or primary-tree files were changed by this
review.

## Authorized review fixes and release-ref policy — initial implementation

The human authorized resolving every review finding and replacing revision URLs
with a Crane version tag and a NixOS 26.x release branch. Root and all 13
retained child wrappers now use `github:ipetkov/crane/v0.24.0` and
`github:nixos/nixpkgs/nixos-26.05`. There is no generic `26.x` flake ref.
Existing optional unstable inputs are unchanged. The root's Nixpkgs lock
snapshot was already on 26.05 and is preserved; only the Crane lock node
changed, using genuine bounded upstream/Nix metadata. A version-tag bump is
intentional, not performed by an ordinary lock refresh.

Implementation:

- `toolchainFor` returns one coherent library/tools/identity record. Overlay
  methods use the final package set; the default Crane bootstrap is separate to
  avoid self-recursion. Crane's own `callPackage` supplies its authoritative
  bound tools and stdenv, rather than reapplying its selector to the caller's
  package set. This also catches native callers injecting cross-bound libraries.
- Toolchain identity uses actual Cargo/rustc paths, independent of provider
  label or explicit/default selection. Treat the ID as opaque. Build/check
  compiler environment overrides are rejected; choose the compiler through
  `toolchain`. Effective direct/function stdenv overrides are validated against
  the bound context. Default spliced Nix-cross libraries remain supported;
  custom cross contracts remain fail-closed. Arbitrary caller hooks and supplied
  producer certificates are trusted configuration, not execution attestation or
  a producer-fidelity pass.
- `retained-packages.nix` alone owns repository lookup. Its shared inventory
  names canonical manifest packages/nested outputs, eliminating alphabetical
  source matching. `stack/package.nix` accepts an optional `packageFor`
  resolver, defaults to direct standalone `callPackage`, and rejects
  overlay/provider customization in the complete-parent `pkgsForSystem` mode.
  Per-system output caching avoids evaluating defaultSystem twice.
- The pin updater validates root original/locked provenance and the explicit
  inventory before any writes. It preserves release refs instead of hardcoding
  lock revisions, tolerates conventional formatting/helper aliases and refuses
  unsupported input syntax instead of inserting conflicting declarations.
- Spike runs require fresh exclusive output directories. Report publication
  replaces a fresh file atomically and rejects aliases to inspected inputs.
  Process-group cleanup runs on success, failure, interruption and exceptions
  with bounded waits. Processes that deliberately escape the group still require
  external containment. Synthetic descriptors snapshot inputs; malformed JSON
  shapes and decoder-limit failures produce incomplete evidence, not false
  qualification or a crash before report publication.

Review-fix checkpoint validation, no compilation (preceding the package-owned
simplification below):

- 90 pure toolchain assertions pass using a tiny dependency-free synthetic Cargo
  workspace under `lib/flake/tests/fixtures/`; shared checks no longer depend on
  real product sources. Real integration checks live under
  `lib/flake/tests/pvl/` and enter through `repo-checks.nix`, with the Crane
  constructor captured by the repository manifest rather than leaking identity
  imports into generic wiring.
- 18 real tagged-Crane no-IFD assertions pass on both x86_64-linux and
  aarch64-linux, including bound-cross rejection, function stdenv overrides,
  compiler-environment rejection, late overlays, operation tools and
  provider-independent identity. Default spliced-cross preservation also passes.
- The before/after hello-rust helper comparison preserves build, base, member
  and fmt/lint/test derivation paths with one identical package set and Crane
  release. Switching the Crane dependency itself intentionally changes affected
  paths.
- Actual wrapper output-path/program parity passes for all 13 parent-injected
  wrappers on both Linux architectures, covering packages, checks, apps and
  shells, plus exported module names. Independent default construction has the
  same comparisons for hello-rust, manager's internalDeps and nested
  llmug-hello. Negative fixtures detect valid-but-wrong checks/apps/shells.
  Module body/host evaluation is a separate gate. All wrapper Crane
  declarations/refs are checked; these are actual wrapper evaluations, not
  child-lock fetch/build tests.
- The original all-wrapper/default full-output test exceeded bounded evaluation
  timeouts. Output caching plus representative default smoke coverage reduced
  the x86 narrow child check to about 10 seconds; final x86/aarch checks passed
  within their 30-second bounds. Whole-root build/host validation remains
  outside this cheap phase.
- 49 spike and 45 ref-updater Python tests pass, covering report aliases/atomic
  publication, lifecycle cleanup, fresh state, descriptor mutation, malformed
  capture/decoder limits, inventory/ref policy and mocked update ordering.
  Unsupported grouped/quoted/inherited input declarations fail before writes. No
  real maintenance update was run.
- The real offline no-deps Abird probe succeeds, observes 24 package
  definitions, leaves manifest/lock unchanged and remains `not_proven`. Its
  successful temporary output is removed after summarizing it here.
- Fenix/oxalica builds and exact producer capture are still unproved. No
  Rust/Nix builds, deployment, staging, commits or pushes were performed.

## Package-owned dependency defaults — accepted simplification

The human selected option 3: keep child wrappers, remove the routing adapter and
handwritten JSON, and make each package constructor own its intrinsic dependency
defaults. This supersedes the initial canonical-ID/registry implementation
above; it does not change Cargo authority, provider selection or the producer
gate.

- All 13 wrappers now directly call
  `(import .../lib/flake/stack/package.nix).mkFlakeOutputs ./default.nix inputs`.
  `lib/flake/retained-packages.nix` and `pkgs/retained-child-flakes.json` are
  removed, not replaced by another production registry or resolver.
- Manager defaults `abirdHostAgent` to the sibling package constructor and
  forwards the supplied `pkgHelper`. Its manifest entry no longer supplies that
  dependency. Explicit dependency injection remains available; `null` disables
  artifact inheritance while retaining the agent's source directory.
- Cloudflare already owns its sibling nixbot/llmug defaults; its redundant
  manifest dependency wiring is removed too. `manifest.nix` retains
  registration, app/export selectors and the general `args` customization seam,
  not repeated intrinsic dependency defaults.
- Parent `pkgsForSystem` injection shares package-set configuration, not
  arbitrary root-only manifest arguments. Independent children use package
  defaults unless arguments are explicitly supplied. Exact sharing needs equal
  sources, package sets, helpers and effective arguments. Existing
  source/helper/workspace layout remains repository-bound; this is not
  independent mirror generation.
- Parity expectations derive from existing manifest paths and nested tooling
  selectors **inside the Pvl identity test only**. They do not route production
  child builds. Ref discovery uses source-tree library references without
  requiring a manifest entry or registry edit.

Cheap no-IFD validation passes on x86_64-linux and aarch64-linux: all 13 actual
parent-injected wrappers agree with current canonical defaults for exported
package/check/shell paths, app programs and module names. Independent default
smokes cover hello-rust, manager and nested llmug. Dependency-default
regressions prove explicit/default manager build/artifact/member equality on the
same final sources, helper propagation into the sibling constructor, explicit
null/source retention and Cloudflare default/explicit dependency equality. Bare
standalone manager evaluation without Crane also remains valid; wrappers supply
Crane. The existing 90 pure and 18 real-Crane assertions remain green. All 56
ref-updater and 49 spike Python tests pass. Automatic discovery finds all 13
wrappers, includes new owned wrappers without registration, ignores independent
external flakes and generated build/dependency trees at source boundaries, and
rejects unsafe paths or malformed inputs before any writes. A focused
independent review found no blockers in the package-owned composition changes.
The ownership convention is recorded in `lang-patterns/nix.md`.

Recipe/wrapper edits change selected Cargo sources: member directories are kept
in full by `mkWorkspaceSourcePath`. Derivation paths therefore changed from the
previous source snapshot; the constructor-equivalence proof holds **on identical
final sources**, not across those file edits. No Rust/Nix builds, source builds,
network fetches, staging, commits, pushes or primary-tree changes were
performed. Full root/host evaluation and expensive producer qualification remain
separate gates requiring authorization. Successful temporary comparison reports
are removed after summarizing the result here.

## Optional Crane inputs — accepted correction

The human asked why non-Rust wrappers declared Crane and authorized removing it.
Uniform input insertion was overbroad: it created unnecessary lock/input and
Rust-overlay setup for unrelated packages. The generic helper already defaults
`crane` to null, so no new flag, registry or language detector is needed.

- Six direct Rust wrappers retain the root's Crane tag: hello-rust,
  hello-rust-isolated, host agent/manager, nats-http-bridge and
  nats-wrecking-ball.
- Seven wrappers omit it: Go/Node/Python/static examples, nixbot, Cloudflare's
  aggregate and nested llmug. All still retain their nixpkgs/flake-utils refs.
- The updater synchronizes Crane **only if declared**; absence remains absence
  in check/write/idempotent maintenance. Required common inputs, root lock/ref
  validation, malformed-declaration rejection and all-wrapper write preflight
  remain intact. Future mixed-language constructors building a Rust dependency
  must supply Crane for that build closure; do not infer this from file
  extensions.
- Identity tests now filter supplied inputs by each actual wrapper declaration.
  Independent defaults use the matching bare or Rust-overlay package set instead
  of forcing Crane into every fixture. Compiler-producing metadata and artifact
  parity check Rust consumers; an intentionally omitted hello-rust declaration
  reaches the valid bare fallback but cannot pass the Crane-artifact gate.
- All 13 parent-injected wrappers still pass export parity on x86_64-linux and
  aarch64-linux. Independent default coverage expands to all seven non-Rust
  wrappers plus hello-rust and manager, preserving the bounded Rust-import
  scope. Module bodies/full hosts and actual compilation remain separate gates.
- 59 ref-updater and 49 spike tests pass; the 90 pure and 18 real-Crane
  assertions remain green. No dependency fetches, builds, lock refreshes,
  staging or commits were performed. Existing ignored child locks can retain old
  unused nodes until normal maintenance refreshes them; declarations no longer
  request those inputs.

## One update helper — accepted consolidation

The human requested folding child-ref maintenance into the existing source
reporter instead of adding a separate standalone script. The reporter is renamed
`update-helper.py`, retaining its external-source behavior behind
`report-sources`; the former pin updater becomes its offline `child-refs`
subcommand. Both old script paths are removed without compatibility wrapper
files. `scripts/update.sh` remains the user-facing entrypoint and calls the
appropriate subcommand.

Subcommands are explicit: source reports never sync refs, ref checks never
perform version lookups, and writes require `child-refs --write`. Existing ref
validation, optional-Crane behavior, preflight and source-discovery safety
remain unchanged. The reporter's SIGPIPE setup is scoped to that command instead
of module import, so offline checks and callers do not acquire unrelated signal
behavior. Generic helper tests consolidate under `scripts/support/tests/`,
retaining separate area files for reporting, ref maintenance, orchestration and
command dispatch.

Validation: all 145 support tests pass (including the original 59 child-ref
regressions and 14 new dispatch/isolation checks); all 49 spike tests remain
green. The real offline `child-refs --check` finds all 13 wrappers with matching
refs. Shell syntax and diff whitespace checks pass. No real report/network
lookups, updates, builds, staging or commits were performed; temporary test
state is removed. The source-unit/tooling docs and their index now name the
unified helper rather than either removed script.

## Commit checkpoint and next-phase preparation

The human authorized the local foundation commit after requesting a single
initialized helper-path variable in `scripts/update.sh`. `UPDATE_HELPER` is set
once from `REPO_ROOT` in `init_vars`, quoted at both subcommand call sites and
used to derive report-failure labels. The entire foundation/context index was
already staged by the human; preserve that prepared index rather than restaging
or rearranging it. Commit remains on the agent branch; no merge/push is implied.

Next phase is producer qualification, not unit-DAG rollout:

1. Establish the immutable committed baseline and rerun cheap tests.
2. Prepare a dependency-free isolated fixture covering ordinary/build/dev edges,
   distinct host/target feature sets, a proc macro and build-script compile/run
   behavior. Define expected units/roles/edges before inspecting captures.
3. Check available external containment and specify network denial, isolated
   writable paths, process-group/resource bounds and a single-job time budget.
4. Ask for explicit bounded compilation/capture permission. Do not treat
   `capture-build` artifact messages, fixture success or synthetic exact labels
   as an exact producer qualification. Missing producer fidelity stays
   `not_proven`.
5. Only after a trusted capture contract exists, validate identical unit
   identity across two capsules/lock stamps, deliberate divergence, build-script
   input identity and fail-closed behavior; otherwise retain the G4+M path.

Foundation baseline is SSH-signed commit `d17ffe53` on the existing agent
branch; no merge or push was performed. Final validation passes 145 support
tests, 49 spike tests, 90 pure assertions, 18 real-Crane assertions per Linux
architecture, all wrapper parity/ref checks, Bash syntax and ShellCheck. The
prepared index was committed together; only the requested variable and closeout
docs were added.

Next-phase containment preflight succeeds: installed `bwrap`, `unshare`,
`prlimit` and `timeout` are available. A harmless immutable `true` executable
succeeds with separate user/PID/network namespaces, a read-only `/nix/store`,
private `/proc` and `/dev`, tmpfs `/tmp` and `--die-with-parent`. No repository
or secret directories were mounted. This proves namespace availability, not full
build containment or producer fidelity. The actual fixture run must additionally
mount only its approved writable state and set resource/time limits.

Proposed first capture permission: dependency-free role fixture, no network, one
Cargo job, at most 300 seconds and a 2 GiB address-space limit; stop on missing
local tools/state rather than fetch. Expected role/edge cases are defined before
running it. Compilation and exact adapter design remain separately reviewed.

No expensive build, provider fetch or graph-adoption decision is authorized by
"move on" alone under the retained cost gate.

## Retained wrapper ref maintenance

Normal maintenance now automatically synchronizes wrapper refs after updating
the root lock and before refreshing existing ignored child locks:

```bash
scripts/update.sh --only-flake
```

After intentionally changing the Crane tag in root `flake.nix`, use that normal
update flow. Updating a release branch advances its locked snapshot; updating a
version tag retains that tag unless the root declaration is explicitly changed.
For focused offline ref synchronization from an already-current root lock:

```bash
python3 scripts/support/update-helper.py child-refs --write
python3 scripts/support/update-helper.py child-refs --check
```

The updater uses `nodes[root].inputs`, not a guessed node named `nixpkgs`: Pvl's
selected root nixpkgs is `nixpkgs_2`, while another node named `nixpkgs` belongs
to a different dependency. It follows each node's `original` release ref, not
`locked.rev`. Repository-bound wrappers are discovered automatically under
`pkgs/` by conventional relative references into `lib/flake`; adding a wrapper
needs no registry edit. Discovery tolerates helper aliases and formatting.
Unsafe paths, empty discovery and malformed input declarations fail before
writes; independently managed external flakes without library references are
excluded. `.git` and conventional generated trees at source boundaries are not
walked or rewritten, while real package directories named `target` or `dist`
remain discoverable. Computed imports without a literal relative library
reference are outside this discovery contract. The release-ref validator is not
hardcoded to 2026, so a future NixOS release needs a root-ref change, not a
Python rewrite.

Existing ignored child lockfiles may still carry the old pins. Refresh them
explicitly through the repository's child-lock update process before assessing
actual child-flake builds. This checkpoint never rewrites ignored locks in the
primary tree.
