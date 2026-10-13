# Rust foundation: NixOS VM qualification setup

## Current main integration — 2026-10-13

Rust foundation is integrated into the local master branches of Pvl and Abird.
Current-input qualification passed all six manager cases in both repositories:
fresh baseline, cache hit, binary-cache export/delete/restore with builds
disabled, ordinary forced warm recompilation, changed warm and independent
changed fresh. Cache transport preserved exact NAR identity and compiled zero
crates. Both warm cases compiled only agent and manager: two workspace, zero
external crates. The changed-source probe and original installed version passed
in both variants. Independent byte determinism remains optional FAIL in both
runs.

Actual committed manager mirrors passed write/check and all four consumption
routes have equal package/build/base/vendor/tool/fleet/check identities. They
join the current VM recipes exactly. The original default manager recipes,
tools, checks and fleet inputs are identical before/after integration in both
repos; existing outputs passed installed version without another build.

Pvl Source validation passed 1,076 assertions and 146 Python tests plus syntax
and native-shell controls. Abird Source validation passed shared byte/mode/type
joins, 562 pure assertions, 90 pure toolchain checks, current policy/toolchain
18 each and actual 24-base/context controls. Twenty native constructor contexts
are supported; four contexts remain explicit declines: controller check-env
projection, two WASM adapters and parent-owned Tauri hooks/assets/strictDeps.
Cross/partial-WASM admission rejects. No 24-product execution, ARM runtime or
universal payback is claimed. The earlier 15.1% timing saving belongs to the
qualified candidate's selected-manager comparison, not these newer-input runs.

All new qualification VMs use 16 CPUs / 16 GiB. Normal systems keep regular
Cargo and their existing default-off policy. Patched Cargo and strict
independent byte determinism remain optional qualification routes. No production
defaults, compiler flags, source fingerprints or outputs were normalized or
switched. Releases continue to use fresh Nix builds.

- pvl: committed source `d82fa09bed7678484638a3de2cb3f84b5aed2c04`, runtime
  `/nix/store/ffia0nfcdpzigd3h2srpsrb2wf4rgxh3-vm-test-run-rust-foundation-pvl-main-integration-16cpu`.
- abird: committed source `544e18818a3456a8858a04db5ff54bd57183e3c2`, runtime
  `/nix/store/cjqj6ckhwla54xccz8v74az73ykj25j8-vm-test-run-rust-foundation-abird-main-integration-16cpu`.

The canonical plan is closed at
`.agents/plans/archive/2026/2026-w40-rust-fabric-implementation.md`. The done
capsule is `.agents/plans/done/2026/w42/2026-w40-rust-fabric-implementation`.
Pvl's done capsule retains the public historical event stream; Abird retains its
local coordination record and current integration events. Raw private execution
artifacts and unmerged historical staging remain in the original R/A custody
worktrees; no historical worker/read/archive unit was reopened. Those trees are
retained to avoid deleting unmerged local state. Active implementation and all
new work now belong in the two main worktrees.

Publication/push and broad adoption remain separate. No additional qualification
build or compiler metadata investigation is selected for this integrated scope.

## Historical qualification cutoffs

## Real mirrors and Abird qualification — 2026-10-13

The current unit is final qualification and review on regular Cargo. All new
qualification VMs use **16 CPUs and 16 GiB RAM**, including smoke and optional
strict diagnostics. This explicit human correction supersedes the historical 1
CPU / 2 GiB cost envelope; earlier 7 CPU / 8 GiB evidence keeps its actual
resource label. Optimize elapsed time by joining identical executed recipes and
rerunning only a failed comparison, never replaying spent private worker units.

Both actual manager mirrors passed immutable candidate generation, --check and
independent provenance review. Original, standalone, composed and in-repository
constructors have identical package/build/base/vendor/tools/fleet/check
identities. Pvl's recipes join its completed regular-Cargo VM; Abird's join the
actual native run below. Validation-only Git revisions pin declared candidate
bytes and modes; they are not production publication or integration revisions.
Pvl: e360fc893a7f8c2ab4129ef4b12aa89de029c211, 295 declared files / 275 emitted
files. Abird: bf72d3e59b2ff0b6d2d4c12b16aee82009d9ecdd, 457 declared files / 278
emitted files. No candidate root refs or indexes were changed.

The actual Abird 24-member source retained its original Nixpkgs, regular Cargo,
full vendor and constructors. Its six required native manager cases all passed:
baseline, unchanged cache hit, binary-cache restore with builds disabled,
ordinary forced warm recompilation, changed warm and independent changed fresh.
Cache transport preserved exact NARs; cache hit/restore compiled zero crates.
Both warm cases compiled 2 workspace / 0 external crates. The changed-source
probe and original installed version passed. Both independent byte comparisons
differed, recorded as optional failures. The original seven-case outer run
remains FAIL: its later legacy comparison lacked the dependency recipe's dummy
source materializer and failed offline before manager compilation. Its partial
JSON is preserved unchanged; the six-case acceptance is independently derived.

The correction includes the actual legacy dependency producers as forbidden seed
outputs and selects only their declared tools/vendor/dummy-source inputs. A
comparison-only single guest runs the unchanged legacy package recipe and
observable source edit, with all tested project/cache outputs absent initially.
The six successful cases were not replayed. The isolated comparison passed
original version and the same changed-source probe, with 13 initially absent
project/cache outputs. Legacy elapsed time was 187.75s / 208 external
compilations; changed warm was 159.34s / 0 external (28.41s, 15.1% less elapsed
time), unchanged warm 112.95s, cached hit 0.35s and cache restoration 5.89s.
These are single observed selected-manager workflows with shared prerequisites,
uncontrolled OS caches/host load and runtime/log checks included, not a complete
24-product cold benchmark or universal payback. The member head NAR was
26,589,144 bytes and package 12,760,592 bytes; these exclude parent-cache costs.
Original constructor/base/vendor/tool identities and default-off policy remain
intact. The new common-driver six-case smoke also passed at 16/16.

All 24 actual member base constructors and 36 actual default-off/toolchain
policy assertions passed. The fresh evaluator took 21.55s and peaked at 569,928
KiB RSS; OS caches were uncontrolled. Platform context evaluation constructed 20
supported native products and recorded four explicit declines: controller
RUST_TEST_THREADS projection, two WASM Trunk adapters without base admission,
and the parent-owned Tauri assets/hooks/strictDeps recipe. Cross and
partial-WASM admission rejected explicitly. Tauri is an authenticated parent
argument capture plus separately checked original policy, not a constructed
Tauri product. This does not claim 24-product execution or ARM runtime coverage.
Default-off routes and Abird's documented helper policy remain intact.

Qualification within this explicit candidate/native/context/measurement scope is
independently ACCEPTED. Review event:
20261013T125426Z-independent-final-candidate-qualification-review.md. Final
public evidence is retained through the R work capsule's dated
20261013T125755Z-final-qualification-evidence root; it includes original failed
logs, separate successful comparison/smoke, immutable candidates, Source pins
and regeneration instructions. No failed target was replayed to retain it.

Next bounded unit is a separately authorized integration review/landing
decision. There is no additional build selected for this qualified scope.
Publication, adoption, 24-product execution, ARM runtime and universal payback
are outside this verdict; do not convert these bounded results into broader
acceptance. Compiler metadata work remains optional and unselected.

## Earlier Pvl regular-Cargo reuse result — 2026-10-13

Required real manager reuse qualification **PASS** on original
Cargo/rustc/Crane. All six cases passed original installed version: fresh
baseline, unchanged Nix cache hit, local binary-cache restore with compilation
disabled, forced ordinary warm recompilation, observable changed warm and
independent changed fresh. Cache hit/restore compiled zero crates and restored
the exported NAR identities exactly. Both warm compilations built 2 workspace /
0 external crates. The changed-source behavior appeared in both changed builds.
Independent fresh cases each logged 226 external / 236 total compilation
messages. No default package/toolchain identity changed; no product flags, hooks
or wrappers changed.

Independent unchanged-recompile and changed-warm/fresh hashes both differ. Byte
determinism is **optional FAIL**, separately recorded under the human's latest
acceptance decision; requiredReuseChecks is PASS. No new metadata cause or
universal semantic equivalence is claimed. Full-foundation completion remains
false: actual immutable manager-mirror consumption, Abird qualification,
24-member cost/payback, platform runtime coverage, independent review and
separately authorized integration/adoption still have their own gates.

Current Source/real-constructor/locality/invalidation checks passed 1,004
assertions, with 30 construction controls in the edit lane. Mirror tests passed
52 and fixture tests 28; native four-variant invalidation passed. These bounded
fixture/Source results do not establish all products/platforms. The
Abird-specific rustWorkspaceDeps fallback is documented policy and remains
intact.

V1's 300-second cold case timed out and remains CLOSED FAILED. V2 ran after
other native tests completed with an explicitly selected 450-second case limit
and unchanged 1800-second framework bound; its cold baseline finished in
171.84s. This does not identify the timing cause or qualify original cost. The
that earlier VM environment used 7 cores/8GiB per guest, independent writable
stores, no IFD/network/remote builders or seeded tested outputs. Local unsigned
cache transport is a disposable-guest test exception, not a production trust
change.

Latest R result event:
`20261013T053238Z-regular-cargo-required-reuse-matrix-pass-optional-determinism-fail.md`.
Registered manager result and ordinary case logs:
`/nix/store/9d5az70yxh5zsck5lqxi79kypwg8d033-vm-test-run-rust-foundation-manager-required-reuse-v2-vm`.
Current public Source/static/refusal evidence bundle:
`/nix/store/fw630dd7hpva1zgwsw3fhd7c0yzhxw6n-rust-foundation-required-reuse-validation-evidence`.

At that earlier cutoff, the next unit was real immutable manager-mirror
validation; the current section above supersedes that work order. retain regular
Cargo and the revised reuse criteria. Byte-metadata investigation is optional,
and no historical private archive or spent manager unit is reopened. No staging,
commit, push or adoption occurred.

## Required reuse acceptance; optional byte determinism — 2026-10-13

The human explicitly made independent-build byte determinism optional. Required
acceptance remains correct Nix cache reuse, Cargo dependency-DAG reuse,
invalidation/locality and all original G1–G11 goals. Project/dependency
reproducibility cannot be guaranteed by this foundation. Releases use fresh Nix
builds; release builds do not replace required reuse/invalidation qualification.

The regular VM route uses original Cargo and `checkDeterminism = false`. It
checks an unchanged Nix cache hit, a local binary-cache export/delete/restore
with build jobs disabled, ordinary unchanged recompilation with dependency bases
retained, changed warm and independent changed fresh behavior. Cache transport
must preserve exact NAR identity; independent recompilation hashes are recorded
separately and do not fail the required lane. The optional
`checkDeterminism = true` route retains strict comparisons and `--rebuild`; the
patched-Cargo entrypoint remains optional and defaults to that diagnostic. No
compiler flags, source filters, Cargo fingerprints or producer artifacts are
normalized to hide differences.

The regular-Cargo reuse lane and observable manager-source change now passed
using fresh declared public snapshots; see the current result above. Do not
continue compiler metadata root-cause investigation for required completion. The
previous hash failures remain genuine optional-diagnostic failures, not reuse
failures or successful full-foundation acceptance. Mirror, parity,
platform/cost, independent review and separately authorized adoption remain
required. Latest R decision event:
`20261013T050429Z-human-byte-determinism-optional-required-reuse-selected.md`.

## Historical optional Cargo result — 2026-10-13

Human approved the exact upstream Cargo PR #16691 ordering patch for optional
qualification only. R now provides patched-cargo.nix, cargo-order-check.nix and
manager-patched-vm.nix under scripts/rust-fabric/qualification. The regular VM
route defaults to regular Cargo; no root-flake check or system package enables
the patch. Regular Cargo and manager derivation identities are unchanged.

The real patched Cargo built, and a small independent-compilation/source-edit
regression passed. The full manager matrix reached four successful build,
packaging and version cases. The original forced-warm byte-equality gate now
passes with exactly 2 workspace / 0 external compilations. Changed warm and
independent changed fresh nevertheless differ in cache and package NAR hashes;
full qualification remains incomplete.

A fresh retained comparison found package differences in anonymous LLVM symbol
suffixes/non-allocated symbol-table data. All 29 allocated ELF sections match;
fully stripped diagnostic copies match exactly. The member head also has manager
rmeta/rlib differences, and independently produced parent cache NARs differ. No
runtime-loaded byte difference was observed in this package pair. The exact
generator of the remaining cache/compiler metadata variation is not yet proved.
Diagnostic stripping changed only owned copies; producer outputs, regular
compiler flags, Cargo fingerprints and production packaging stay intact.

At that historical cutoff, the next unit was parent cache/compiler metadata
variation. The latest human decision above supersedes that work order; keep
retained artifacts for an explicitly selected optional diagnostic. Keep optional
patched results separate from regular Cargo raw cache reproducibility and
original cost/platform/ mirror/integration/adoption gates. Removing the backport
requires that its fix be present in the regular pinned Cargo, not merely merged
upstream.

Implementation, reproduction and actual evidence are in the synchronized VM
note. Current R outcome event:
`20261013T044227Z-optional-cargo-qualification-implemented-runtime-sections-equal-next-metadata-gate.md`.

## Confirmed VM determinism cause — 2026-10-13

A fresh human-selected diagnostic retained the baseline and Nix .check outputs
of the original manager member-layer recipe. Only target.tar.zst differed. Both
tar streams have 39 entries with identical order and headers. Every archived
payload matches except Cargo's binary dep-info for the agent and manager
libraries. Those two files contain identical raw dependency-record multisets (27
agent / 58 manager), identical format/version/count/environment bytes, and
differing record order only. Executables, rlibs, rmeta, text .d files and other
fingerprint payloads match. Warm compilation remains 2 workspace / 0 external.
Baseline build/package/version passed.

The pinned Cargo 1.95.0 (f2d3ce0bd) writer collects paths in a HashMap, iterates
it without sorting, then serializes the resulting vector. HashMap random seeds
vary that iteration order across Cargo processes. Crane archives the binary
dep-info unchanged, so Nix correctly rejects different cache-output bytes. This
establishes the cause for the current sandboxed pair, not every historical
unsandboxed mismatch. No compiler/toolchain/fingerprint or producer changes were
made; this diagnostic collection is not successful warm qualification.

Evidence and exact upstream references are in the VM note. Next work must
address Cargo dep-info serialization through a compatible solution. The current
contract forbids patched Cargo or fingerprint reimplementation: do not silently
normalize/delete binary fingerprints, waive the gate or label final-binary
identity as cache-archive identity. Build-path, tar timestamp and tar-order
experiments are finished for this proved pair. Full qualification remains open.
Current R raw root-cause event:
`20261013T030644Z-vm-cargo-dep-info-record-order-root-cause.md`.

Status on 2026-10-13: implemented and boot-tested; actual manager baseline and
version passed, forced warm output equality failed. This is the current VM
route, separate from the spent Podman M24 and its admission/cost protocol.
Source and execution evidence live only in R:
`/home/pvl/src/nix/worktrees/rust-fabric-foundation-20261001`.

## Matrix and isolation

The stock `pkgs.testers.runNixOSTest` driver boots warm and fresh guests with
independent writable disks and explicit store images. Neither mounts the host
store. Both instantiate the same pinned recipe module inside the guest and check
its derivations against host evaluation before building. Seed closure checks
exclude all tested package/member/base/recursive-parent Cargo outputs. Allowed
seeds are actual source/vendor/lock materializers, compiler and native
runtime/build tools. No private cache, prior receipt or whole repository enters
the image. Network fetching, substituters, remote builders, sandbox fallback and
IFD are disabled. Nix sandbox-build-dir=/build is verified; a guest marker
outside the sandbox must be hidden.

Cases execute in order: fresh baseline; unchanged forced warm (`--rebuild`);
controlled manager-source comment change with warm cache; the identical changed
recipe in the independently seeded fresh guest. First failure stops later cases.
Compare installed version, NAR hash/size/references and ordinary Cargo Compiling
frontiers. Matching derivations alone is insufficient. Warm cache exists only
inside the running warm guest; no separate historical success receipt or frozen
warm-store copy is issued by this harness.

That historical run used 7 cores / 8 GiB per guest. New lanes use 16 cores / 16
GiB and a 32-GiB writable disk by the current human decision. Commands and
checks share a 300-second case deadline; log transfer is measured and bounded by
the stock framework timeout. The 1800-second global timeout also bounds cleanup.
Image preparation/boot are separate observed costs. This does not certify
original 1 CPU / 2 GiB performance, old read-budget/fullstat9 custody, or all
qualification gates.

## Running the smoke

From R, use the already selected immutable nixpkgs input:

```bash
nix build --impure --file scripts/rust-fabric/qualification/smoke-vm.nix \
  --arg pkgs 'import /nix/store/3a5jzlyfgc4imvkf2qibs5yb35nf0lz1-source { system = "x86_64-linux"; }' \
  --out-link tmp/nixos-vm-qualification-20261013/smoke-result-new \
  --print-build-logs
```

Successful outputs contain `matrix-observations.json` and per-case logs. Current
driver prints bounded partial JSON prefixed `RUST_FOUNDATION_VM_RESULT` to the
normal Nix build log even on failure, because failed derivation outputs are
removed. It also prints a bounded failing guest log tail. Retain the outer build
log in an owned, distinct file for each new unit.

## Manager inputs and regeneration

The retained current invocation is
`tmp/nixos-vm-qualification-20261013/manager-vm-ready.nix`. It uses pinned
nixpkgs `3a5jzlyfgc4imvkf2qibs5yb35nf0lz1-source`, Crane
`rkz006xkgqrn2dav1274ggmqf00p9w46-source` and the public immutable bundle
`/nix/store/353cid07mrklrl4zhdn3qyai1xkvrrik-rust-foundation-vm-projections`.
The V4 run is spent; its invocation documents reproduction, not an instruction
to replay it without a meaningful selected implementation change.

For a fresh implementation unit, regenerate only these public inputs, preserving
bytes and modes: root Cargo.toml/Cargo.lock/.cargo plus the declared five member
directories `pkgs/examples/hello-rust`, `pkgs/support/nats-http-bridge`,
`pkgs/tools/abird-host-agent`, `pkgs/tools/abird-host-manager` and
`pkgs/tools/nats-wrecking-ball`. Enumerate current cached and intended untracked
files with scoped `git ls-files`; do not include ignored private outputs or
secret trees. The initial inventory is retained as
`tmp/nixos-vm-qualification-20261013/source-projections.json` (143 files,
4,230,664 bytes). Changed source differs only by the intended controlled manager
comment; check the actual diff before realization.

Copy the five original public helper modules into a support projection:
`lib/flake/{pkg-helper,rust-closures,rust-compile-context,member-bases,rust-toolchain}.nix`.
Place baseline, changed and support as children of one bundle, then register
that bundle with `nix-store --add`. The workspace planner reads its parent, so
standalone source store roots are unsuitable. Source-owned constructors,
features/options/hooks, full lock/vendor and compatibility guards stay intact.
The manager adapter checks these originals against current R before evaluation.

Write an owned invocation under root tmp/ importing `manager-vm.nix`, with the
pinned package inputs and literal bundle child paths. Evaluate
`manager-recipes.nix` with the same inputs; pass the resulting recipes to
`manager-seeds.nix { inherit recipes; }` for `seedPaths`. The retained
`manager-recipes-eval-v2.nix` and `manager-vm-ready.nix` show exact arguments.
New source/helper inputs must be rechecked rather than transplanting the old
baseline or claimed receipts. Once the new unit is selected and inputs checked:

```bash
nix build --impure --file tmp/<owned-unit>/manager-vm.nix \
  --out-link tmp/<owned-unit>/manager-result --print-build-logs \
  >tmp/<owned-unit>/manager-build.log 2>&1
```

Use direct module evaluation as above; never use a `path:` flake shortcut. Test
outputs must be absent even if their `.drv` files exist. Seeds preserve
realization context only for allowed tools/source materializers; cargoArtifacts
is never a seed selector. Full guest offline builds prove seed sufficiency.

## Results and limits

The final smoke output is
`/nix/store/4f9zhi6csjm05y4y997pkbk7rv2605as-vm-test-run-rust-foundation-vm-smoke`.
Its report has size 7849 bytes and SHA256
`0c0c2b6778fe96300df2c2e3d58835a2afe728ad4c5f11507432a8285d6fcd0b`; all four
cases passed, both guests checked two excluded outputs, and changed warm/fresh
NARs matched. Boot was 27.74 seconds; framework script elapsed 35.32 seconds.
This shell probe validates the harness, not manager Cargo reuse.

Actual manager V4 log:
`tmp/nixos-vm-qualification-20261013/manager-v4-build.log`, 247445 bytes, SHA256
`2c375ff1100b81ae7f958311273b3263452a587bc83d75c34373a157bccbae2c`. Both guests
booted, instantiated exact recipes and passed excluded-output absence checks.
The baseline and installed version completed before unchanged warm began. Nix
rejected rebuild of
`97rg1y03xan751brq5mnwrm5gh9v0x4j-abird-host-manager-build-0.1.0.drv` because
output `cs5asdlpplqphajiw7dxf5w2h4bmfcf4-abird-host-manager-build-0.1.0`
differed. The retained warm diagnostic shows exactly agent and manager Compiling
lines, zero external Compiling lines, fixed /build/cargo-workspace-source paths
and a 1m17s release build. Thus fixed sandbox paths alone are insufficient for
determinism in this scope. At the V4 cutoff no specific archive field or causal
mechanism had been established; the fresh diagnostic below supplies it. Changed
manager cases were not run. V4 predates partial-report printing: its failed test
output disappeared, so a standalone baseline NAR receipt/full baseline Cargo log
is not retained; do not reconstruct or reuse one from control-flow evidence.

Earlier setup failures were typed path conversion, workspace-parent visibility
and an omitted Cargo.lock materializer input; these reached no Rust acceptance
result. `builtins.toPath` returns a string; use literal Nix paths or `/. + path`
when an isPath guard is required. `builtins.storePath` preserves exact
registered seed roots; a typed additionalPaths value may otherwise be recopied
under a new basename. Normalize bundle child seeds to their registered store
root. Guest-side recipe instantiation avoids seeding recursive bootstrap `.drv`
closures. Explicit seed selection includes actual cargoLock and stdenv/source
materializer inputs; it never enables fetching to cover omissions.

Next unit: an artifact-determinism implementation fix, then the same matrix.
Archive-reader work remains closed; avoid further VM infrastructure expansion.
CargoFresh is not_observed, qualificationComplete=false, and full G1-G11,
original cost, mirror, Abird/platform and integration/adoption remain open. No
production defaults, commits, pushes or merges were made by this setup. Current
R raw validation event:
`20261013T023437Z-nixos-vm-matrix-implemented-and-manager-warm-refused.md`.

## Fresh diagnostic evidence and causal chain

The fresh diagnostic was explicitly selected by the latest human request to
quickly find the cause. It extended the existing VM test with --keep-failed on
its forced rebuild, inspected only outputs freshly produced in that guest and
retained both archives. No old private artifact or receipt was opened. Both old
M24 and old reader cases remain closed. The stock framework cleaned up both VMs.
A successful test derivation here means diagnostic collection completed: its
actual status is EXPECTED_OUTPUT_MISMATCH, qualificationComplete=false.

Retained diagnostic output:
`/nix/store/fi62hnfwb06bhvp8spq7wsbf4xqnspar-vm-test-run-rust-foundation-artifact-determinism-diagnostic`.
Owned reproducible source and logs:
`R/tmp/nixos-vm-determinism-20261013/{diagnose.nix,diagnose.py,compare.py,build.log,source-inventory.json}`.
The result link retains the stock-framework output in the same directory.

- artifact-comparison.json: 2,681 bytes, SHA256
  `5cede251cfb427329a2b08db414cde013b5e238d2b544440c842021a27ed896f`.
- matrix-observations.json: 8,148 bytes, SHA256
  `c3949aa1a935201f293b8b4dd0c708e693ddf3d267fea3cc72c21c188c1e05ca`.
- baseline-target.tar.zst: 26,616,273 bytes, SHA256
  `237390c48882c525e3f27f5e708d6127151be8d678f64bd030b8aadf248b30c3`.
- checked-target.tar.zst: 26,616,268 bytes, SHA256
  `5e0e0b5c3cc8f0c042c4bdd132aecb9f6dd67ee808d7e806c504abf944c234aa`.
- dep-info-order-proof.json in the owned tmp directory records exact raw-record
  multiset equality, differing order, identical prefix/suffix and full byte
  consumption for both files. It reads the observed version-1, no-checksum,
  zero-environment-record files using Cargo's documented layout, without
  changing any artifact bytes or implementing Cargo freshness decisions.

The files are
`release/.fingerprint/abird-host-agent-b905b9f9bdf28f26/dep-lib-abird_host_agent`
(608 bytes, 27 paths) and
`release/.fingerprint/abird-host-manager-c53a7f9509bd9602/dep-lib-abird_host_manager`
(1,593 bytes, 58 paths). Both first differ at byte 11 inside the first record.
For example, agent first path is src/sha256.rs versus src/instance_backup.rs.
All complete raw records occur with the same multiplicities; no path, checksum,
format, dependency set or environment value changed.

Upstream mechanism is verified against the exact Cargo commit reported by the
real build:
[Cargo f2d3ce0bd dep_info.rs](https://github.com/rust-lang/cargo/blob/f2d3ce0bd/src/cargo/core/compiler/fingerprint/dep_info.rs).
RustcDepInfo.files is a HashMap (line 33); translate_dep_info consumes it in
iteration order (349-358); serialize emits the vector in that order (191-209).
The parser later rebuilds a map from those records (446-468); ordering carries
no extra dependency semantics in this implementation.
[Standard HashMap documentation](https://doc.rust-lang.org/std/collections/struct.HashMap.html)
documents random seeding. The observed .d source inputs are byte-identical;
Cargo's unsorted map traversal introduces the differing binary record order.
Crane's pinned installCargoArtifactsHook archives these bytes unchanged, despite
normalizing tar time/ownership. Compression then produces different output
hashes, which explains the required Nix failure.

Baseline including packaging/version took 149.17 seconds; forced warm took 81.87
seconds. Guest images/boot/evaluation are separate framework costs, not original
cost qualification. Baseline compilation counts include parent check/build/test
priming; only unchanged warm's 2 workspace / 0 external count is the relevant
bounded reuse observation. No changed manager cases were run.

Diagnosis is complete for this pair. Select a supported solution or explicitly
revisit the Cargo/cache-serialization compatibility contract before production
changes; retaining existing Cargo plus untouched raw binary dep-info cannot
promise byte-identical archives across independently compiled runs. No custom
fingerprint normalizer, fingerprint deletion or gate waiver was implemented.

## Upstream remedy researched before human approval

Read-only research after the human asked how to proceed found
[Cargo PR #16691](https://github.com/rust-lang/cargo/pull/16691/files), which
addresses this exact binary dep-info ordering defect by importing BTreeMap and
changing RustcDepInfo.files from HashMap to BTreeMap. The inspected proposed
commit is 074980c2670522e3bde8acb9a25b40510f78626c. GitHub's primary API was
checked live on 2026-10-13: state=open, merged=false, updated_at=
2026-07-06T04:34:05Z. This is a proposed upstream remedy, not proof of a
released Cargo version containing it or of runtime acceptance in this
repository.

Recommended next route, if strict byte-identical cache artifacts remain
required: permit a narrow, explicitly documented exception to the design
contract's no-patched-Cargo rule for this exact upstream ordering fix; prepare a
pinned opt-in toolchain backport; validate the actual writer with an independent
minimal compile/recompile regression; then regenerate the manager VM inputs and
run the existing four-case matrix without the diagnostic --keep-failed path.
Producer/consumer compile-context identities must follow the changed Cargo path:
never relabel or transplant an old cache as compatible. Dependency bases will
need fresh qualification for that toolchain. No patch, toolchain build, default
change or contract exception has been selected or implemented by this research.

If preserving unmodified Cargo is mandatory, the alternative is an explicit
qualification-contract change: compare generated binary dep-info records
semantically while retaining strict byte identity for executable/library
payloads and final packages. That would acknowledge raw cache-archive
nondeterminism; it must not be described as passing the original raw-output Nix
--rebuild gate. A production normalizer/parser is a third implementation burden
and is not the recommended route. The choice is pending with the human; no
further archive/path experiments are needed to select it.

## Approved optional qualification Cargo route

The human approved patched Cargo for qualification only on 2026-10-13. This
supersedes the pending compatibility choice above. Regular systems retain
regular Cargo; optional qualification is explicitly selected and is never
registered in root-flake checks or system packages. The design contract now
contains only this narrow upstream-ordering exception. Removing the backport
requires that the fixed code actually be included in the regular pinned Cargo;
merging upstream alone does not update our immutable pin.

Implemented files in R/scripts/rust-fabric/qualification:

- patched-cargo.nix and cargo-dep-info-order-16691.patch: original Cargo 1.95.0
  Nixpkgs recipe plus the upstream two-line ordering fix. Existing Nixpkgs
  patches, bootstrap recipe, install checks and compiler remain in place. Only
  diff filename prefixes are adapted to the Rust source's src/tools/cargo
  layout; semantic hunks are unchanged. Rebased patch SHA256:
  70456cea216404c591604f9ebb693b949ef69a58cbdf52b4e6512073fa3951eb.
- cargo-order-check.nix: two actual independent compile runs compare all binary
  dep-info files; a source edit must change executable behavior from 36 to 37.
  This passed with the real patched Cargo and original rustc. The explicit C
  linker is needed because pkgs.runCommand uses stdenvNoCC.
- manager-patched-vm.nix: optional entrypoint that snapshots only the patch and
  Cargo recipe, binds qualification operation tools/Crane to patched Cargo and
  derives actual tool/vendor/source seeds. The host and guest instantiate the
  exact same qualified recipes with no IFD.
- manager-vm.nix / manager-recipes.nix: default qualificationToolingSrc=null
  retains regular Cargo. The optional path is only supplied by the patched
  entrypoint. Existing original recipe/source/closure guards remain required.

Regular Cargo is 05vdg0qyjpk27rf0ijylpz3x5hr0gp2r-cargo-1.95.0.drv; the regular
manager member layer remains exactly
97rg1y03xan751brq5mnwrm5gh9v0x4j-abird-host-manager-build-0.1.0.drv. Explicit
patched Cargo is hh65jyhcss2xq4nasmflzhg2pw73kvri-cargo-1.95.0.drv and its
manager layer is
2vzdmg6srx1k7bx2bccm329bp3lf5y2d-abird-host-manager-build-0.1.0.drv. Qualifying
a changed Cargo uses genuinely new bases and contexts; no old output is
relabeled compatible. The source/compiler/runtime constructors and full
lock/vendor policy are preserved. The patched Cargo native build took 6m07s
release compile time, outside the VM testcase and original performance gates.

To run these optional tests, from R:

```bash
nix build --impure --file scripts/rust-fabric/qualification/cargo-order-check.nix \
  --arg pkgs 'import /nix/store/3a5jzlyfgc4imvkf2qibs5yb35nf0lz1-source { system = "x86_64-linux"; }' \
  --out-link tmp/<owned-unit>/cargo-order-check --print-build-logs
```

Generate the same public workspace/support projections described above. Write an
owned invocation importing manager-patched-vm.nix with the original pinned
pkgs/pkgsPath/cranePath, recipeSupportSrc, baselineSrc and changedSrc. This
entrypoint selects its explicit qualification tool snapshot and seed inventory;
do not pass a regular-Cargo seed list or change source-owned constructors. The
retained invocation is
R/tmp/nixos-patched-cargo-qualification-20261013/manager-vm.nix. Once prepared:

```bash
nix build --impure --file tmp/<owned-unit>/manager-vm.nix \
  --out-link tmp/<owned-unit>/manager-result --print-build-logs \
  >tmp/<owned-unit>/manager-build.log 2>&1
```

For the regular diagnostic route, use manager-vm.nix with null/default
qualificationToolingSrc and its explicit reviewed seeds. Raw unpatched cache
archives are known to differ in Cargo dep-info record order; this does not
invalidate the observed compiled-payload equality and 2-workspace/0-external
warm dependency reuse. Patched results must retain their environment label and
must not certify unpatched cache byte reproducibility or original cost/platform
acceptance. All other G1-G11/integration/adoption requirements still apply.

## Actual patched manager matrix and remaining metadata boundary

Current actual normal manager test:
R/tmp/nixos-patched-cargo-qualification-20261013/manager-build.log and
manager-partial-result.json. Its test derivation is
nd6gg6jp9jri1ih4abxz6rxjnvwlwg7d-vm-test-run-rust-foundation-manager-patched-cargo-vm.drv.
Guest boot: 110.86s; nine tested-output absence checks per guest. All four cases
passed ordinary build/package/version and log checks: baseline 273.20s,
unchanged forced warm 101.76s, changed warm 89.20s, independent changed fresh
232.01s. Unchanged warm and changed warm each compiled 2 workspace / 0 external
crates. Baseline and unchanged forced warm NAR identities match. The final
changed warm/fresh equality assertion failed for member archives and the final
package, under identical actual derivations/inputs. No acceptance predicate was
weakened or called PASS for that equality.

A new collection warmed only the actual dependency base, skipping the already
proved forced warm and unnecessary baseline package. It reproduced changed
warm/fresh NAR inequality. The stock framework's directory copier followed the
Cargo .prev symlink, which cannot resolve to a guest-owned parent on the host;
it failed during warm-artifact transfer. The current failed test's unregistered
output directory still retained the copied warm package/member archive and logs.
Earlier blanket assumptions that all failed test outputs vanish are too strong:
they are not registered/successful receipts, and retention must be checked
explicitly. Normal-log partial reports remain necessary. No old historical
receipt or private archive was reopened to make this correction.

The retained warm data was explicitly copied/hash-inventoried under
R/tmp/nixos-patched-cargo-changed-diagnostic-20261013/retained-warm. A
subsequent fresh-only collection copied ordinary archive files individually and
kept the package plus the actual parent archives. Successful diagnostic output:
/nix/store/x2l0qc36vm3fr19fmkwwxarjalqzwa0a-vm-test-run-rust-foundation-patched-cargo-fresh-artifact-collection.
This is diagnostic collection success, qualificationComplete=false. Owned
sources/logs: tmp/nixos-patched-cargo-fresh-collection-20261013/collect.nix,
collect.py and build.log. No old warm cache was inserted into the fresh guest.

Comparison Source and JSON:
tmp/nixos-patched-cargo-changed-diagnostic-20261013/analyse.py and
artifact-differences.json. Exact retained member heads differ only in manager
executable, nixbot executable, manager rmeta and manager rlib payloads; binary
Cargo dep-info files match. The final wrapper script matches and only the
wrapped ELF differs. Symbol comparison found ten anonymous-symbol names with
suffix .llvm.2084905500565764012 versus .llvm.10002465930404946036.

All 29 SHF_ALLOC sections match bytewise, including .text/.rodata and relocation
and dynamic data. Stripping _only diagnostic copies_ using ordinary binutils
produced identical complete files, SHA256
9ab788c42b0b3b00abeb9a5ad6ff1fce486df51e5ba7521c902381da8c7babbe. Proof is
tmp/nixos-patched-cargo-changed-diagnostic-20261013/elf/runtime-section-proof.json.
No producer/cache fingerprint or production binary was modified. This narrows
the package mismatch to non-runtime ELF symbol-table data for this pair; it does
not yet prove the cause of the parent archive/rmeta variations or raw cache
reproducibility.

The actual warm/fresh parent NAR identities differ for both the admitted manager
base and its genuine subset parent. Warm/fresh manager base narSize is
98,955,064 / 99,004,416; subset parent narSize is 26,773,376 in both with
differing narHash. These are the same recorded producer identities,
independently built in guest-owned stores. Retained fresh parent archive files
are available in the successful collection output for the next unit; use
existing evidence before another build. Full original performance, locality,
mirror, Abird/platform and independent integration/adoption requirements remain
open.

## Regenerating the current required reuse lane

The public evidence bundle above retains both selected manager wrappers, source
pins, Source/locality test wrappers and fixture Sources. Copy it into a fresh
owned directory directly below R/tmp, then make that copy writable. Its relative
imports resolve to the current qualification support in R. Immutable manager
source snapshots, pinned nixpkgs/Crane and helper support remain explicit store
paths; the observable edit changes only manager src/main.rs. Do not substitute a
dirty whole-repository snapshot or seed tested outputs. The raw root-store
source must be nested below a containing snapshot directory so the fail-closed
reader can inspect its parent; no broad /nix/store read exception is selected.

For a fresh selected reproduction from R, use the copied manager-v2-vm.nix:

```bash
nix build --offline --impure --option allow-import-from-derivation false \
  --print-build-logs --file tmp/NEW-OWNED-EVIDENCE/manager-v2-vm.nix \
  --out-link tmp/NEW-OWNED-EVIDENCE/manager-result
```

The regular route defaults to checkDeterminism=false; no patched Cargo enters
this recipe. Select checkDeterminism=true explicitly only for optional strict
reproducibility work. A cached outer VM result is retained evidence, not a new
guest execution; select a new case name for a genuinely fresh run. Historical
spent private units are never used as the reproduction route.

Source checks inspect assertion records/counts exposed by integration tests,
including derivation passthru assertions; do not deepSeq the whole derivation's
recursive package set. Both smoke modes and the native four-variant fixture
result have registered outputs; exact paths are in the retained completed-checks
report. Temporary successful execution files can be cleaned after their public
evidence is retained; failed V1 diagnostics remain in the evidence bundle and
ordinary Nix log under its exact derivation.
