---
id: 2026-w40-rust-fabric-implementation
state: active
created: 2026-10-02
---

# Rust foundation

## Objective

Finish qualification of the existing Cargo/Crane cache design: member-local
source closures, shared full-lock dependency artifacts, genuine strict-subset
inheritance, preserved package contexts, and immutable standalone/composed
mirrors. Establish correctness and useful measured speed before adoption.

## Current state

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

Current VM result (2026-10-13): setup and four-case smoke passed. The real
manager baseline/version passed; forced warm output equality failed despite
fixed sandbox paths and exactly two workspace/zero external compilations.
Changed manager cases were not reached. The cause is Cargo binary dep-info
record ordering; next select a compatible serialization solution using the
existing matrix; see the VM note below. Earlier M24/reader records are
historical and remain closed.

Human resumed on 2026-10-12 with preapproval for validation and finishing
implementation. M21's original manager build and installed version 0.1.0 passed.
M22 completed current Source/control/custody/admission and the original
seven-stage runtime once, then CLOSED exit 1 at the required forced warm
`--rebuild`: Cargo finished, but Nix rejected differing output bytes. BODY30 and
native300 are spent; helper20 passed inside native300. The complete 3,351-byte,
30-line log recorded two workspace and zero external dependency compilations.
This establishes bounded observed dependency compilation reuse, not successful
warm acceptance, CargoFresh or provenance qualification. M21's baseline and
observed eight rows remain intact. The original G1-G11 matrix, deterministic
warm archive equality and the 1 CPU/2 GiB cost case remain open. Implementation
work, current qualification sources, raw decision events and actual evidence
live only in `/home/pvl/src/nix/worktrees/rust-fabric-foundation-20261001`. The
two main worktrees contain handoff information only. Read their indexes first,
then use the current handoff as the sole compact context route.

M23's separately labelled retention diagnostic is now CLOSED FAILED after fresh
current capture, genuine QA4, final12, actual Source89 v2 normal/optimized,
genuine original17 and the reviewed seven-stage chain. Its complete ordinary log
is 3,510 bytes/31 lines, two workspace and zero external compilations, one
Finished line, and an exact admitted derivation/expected output/retained
`.check` mismatch join. Native300 is fully charged and closed; CargoFresh
remains not_observed, provenanceQualified and requiredGoalMet are false. The
sole argv delta was exact-step Nix `--keep-failed`; original hooks, recipes and
failure predicates remain intact. The separately reviewed exact two-output
comparator then closed once, exit 1/empty stderr,
`CLOSED_ARCHIVE_MONITOR_REFUSAL`; Source25 is spent and no accepted comparison
or artifact-read assurance was issued. Causality remains unproved. Native
outcome authority is
`20261012T142500Z-manager23-retention-warm-mismatch-closed.md` in R; the earlier
134905 and 141341 raw cutoffs remain unchanged. The earlier reader failure is
`20261012T143200Z-manager23-bound-artifact-monitor-refusal-closed.md`.

Subsequent independent public Source proof established two deterministic
bootstrap compatibility blockers: the isolated Python wrapper inserts
`PYTHONNOUSERSITE`, which the original controller denies despite all four
isolation flags being 1, and its `putenv` then `execv` call graph requires a
second exec prohibited by unchanged mode0. This does not identify V3's exact
opaque first failure stage or any archive cause. Compatibility Source authority
is `20261012T144200Z-manager23-public-python-bootstrap-compatibility-proved.md`.

Fresh V6 bounded archive comparison is CLOSED SUCCESS, once0/emptystderr,
unchanged mode0child0/reaped/violationNONE. Child READ98,472,199/knownaggregate
98,733,304 stay within128MiB, kernel5,290,449 countedonce. Both compressed
bodies total53,213,209actual/53,213,211requests includingEOF; each80entries/
89,354,240decoded/18,788metadata. Sameentryset,11metadata+15regular-payload
differences (7dependency-info/6exe-library/2other), fingerprint/build-script0.
Compressed/tar/map equality false. Sameparent checked without parentbodies;
fulltreeNone/globalFalse/qualificationFalse. This rules out order-only for
observedheads, not fields/rootcause. No raw payload/private names/paths,
extraction or recipe/hook changes. Relevant paired79module/57Sourcefile context
matches, not globalstartupcert. Current result authority is
`20261012T150400Z-manager23-bound-archive-comparison-success-closed.md`.

Semantic-v1 pure74 controls passed; reader v1 and direct-body-v2 both closed
UNKNOWN_API/no accepted result/spent25 each. Correcting the whole executed-code
envelope did not resolve refusal; no actual `.d` path or metadata-field cause
was issued. Reader work is closed. Historical220855 selected fresh M24 sandbox
first-manager qualification; it now closed at a prerequisite namespace refusal,
without a successful baseline or authority for its warm follow-up. The selected
environment delta is sandbox=true, sandbox-build-dir=/build,
sandbox-fallback=false; original rootless isolation, seccomp/caps,
cache/NAR/custody, recipes and flags remain. No environment experiment alone
closes G1-G11 or authorizes default adoption.

M24 current Source, actual controls, capture, genuine QA4, final12/Source89 and
closed17 review completed. Main executed the unchanged seven-stage chain once:
BODY30 and original fresh custody/admission passed; helper20 passed inside
native300. The first ordinary prerequisite build refused Nix sandboxing because
the worker could not use the required kernel namespaces. The manager build,
packaging and version were not reached. Native300 is fully charged/closed, no
retry or fallback; requiredGoalMet/runtime qualification remain false. The owned
runner reports its container absent; the outer caller establishes only its own
direct-child wait. This does not prove that the host globally lacks namespace
support or identify the precise denied operation. The varying-path hypothesis
remains unproved. M24 is spent and must not be replayed.

Use the four-case matrix: fresh sandbox S0, forced warm S0, controlled changed
S1 warm, independent fresh S1. The last pair uses identical declared inputs and
recipes while varying cache availability. Check rebuild frontiers, output/NAR
hashes and installed behavior; derivation equality alone is insufficient.

## Acceptance

All original goals G1–G11 and gates remain active: actual manager build/version;
forced warm Cargo reuse; peer/comment/member-manifest locality; strict-subset
inheritance; no IFD; complete immutable mirror ownership; standalone/composed/
in-repository parity; generic forwarding; Abird 24-member cost and platform
coverage; useful payback; independent review; separate human integration and
adoption authority.

## Work order

Semantic-v1's 74 pure controls passed once; both subsequent semantic reader
cases v1 and direct-body-v2 CLOSED FAILED at UNKNOWN_API with empty comparator
stdout. Each Source25 grant is spent, with no replay/refund. Correcting v2's
executed-code envelope did not resolve the refusal. No actual `.d` path,
metadata-field or causal result was issued; refused syscall and partial access
remain unproved. Archive-reader work is closed, with Sources/results frozen.

M24's fresh first-manager environment experiment
`rust-foundation-manager24-sandbox-20261013` is now CLOSED FAILED. Its only
worker delta was `sandbox = true`, `sandbox-build-dir = /build`, and
`sandbox-fallback = false`, testing the stable `/build/cargo-workspace-source`
assumption. The original rootless/read-only/ network-none/private-PID/cgroup
boundary, narrow capabilities followed by UID/GID1000 and capabilities0/NNP,
seccomp, cache/owner/fullstat9/NAR, registration/bridge, no-fetch/no-IFD and
recipes/hooks/features/flags/wrappers were retained. No SYS_ADMIN, unconfined
seccomp or fallback was used.

M24 did not select a sandbox-capable execution environment or namespace
isolation change. The later human-authorized NixOS VM implementation and its
actual result below now determine the next work. Ordinary `build-dir = /build`
fixes only the parent and still allocates a variable temporary child path; it is
not equivalent to the sandbox's `/build`. Do not replay M24, silently disable
sandboxing or reopen archive-reader work. Only a successful fresh admitted
baseline can support its fresh original forced warm case; all warm,
locality/subset, no-IFD, mirror, Abird/platform/cost/payback and
integration/adoption gates remain open.

## Context

- Handoff/results/source regeneration:
  `.agents/docs/notes/tooling/rust-foundation-main-handoff-2026-10-12.md`.
- Architecture and rejected alternatives:
  `.agents/docs/design-patterns/rust-foundation.md`.
- R's active implementation plan/work README and raw events contain detailed
  coordination state. Main worktrees do not carry the qualification capsule.

Current independently reviewed M24 closed outcome in R:
`20261013T004841Z-manager24-sandbox-prerequisite-namespace-refusal-closed.md`.

## NixOS VM implementation and current result

The human-authorized NixOS test framework is implemented in R under
`scripts/rust-fabric/qualification/`. Two disposable guests have independent
writable seeded store images, no host-store mount, no remote builders or
substituters, no guest network fetching and no IFD. Nix uses sandbox=true,
sandbox-build-dir=/build and sandbox-fallback=false. Original manager
Cargo/Crane recipes, compiler flags, full lock/vendor and compatibility guards
remain unchanged.

The final smoke passed baseline, forced unchanged warm, changed warm and
independent changed fresh, including exact guest derivation identities,
seed-output absence, installed behavior and NAR equality. The actual manager V4
baseline build/version passed; its forced unchanged warm rebuild failed Nix
output equality. Ordinary warm logs contain exactly two workspace compilations
(agent and manager) and zero external compilations, both under
/build/cargo-workspace-source. Fixed sandbox paths alone are insufficient for
artifact determinism in this case. The subsequent retained pair proves Cargo
binary dep-info record ordering as the current cause (see confirmed result).
Changed manager cases stopped at that first refusal and were not run.

At that historical cutoff, the next work was an artifact-determinism fix with
the compatibility contract, followed by this existing matrix. Do not replay a
spent case, expand the VM harness, or reopen archive-reader work. CargoFresh
remains not_observed and full qualification, original cost, mirror,
Abird/platform and integration/adoption acceptance remain open. The 7-core/8-GiB
guest environment is separate from the original cost gate. M24 remains closed.

Reproduction, seed selection and retained evidence are documented in
`.agents/docs/notes/tooling/rust-foundation-nixos-vm-2026-10.md`. Current R
validation event:
`20261013T023437Z-nixos-vm-matrix-implemented-and-manager-warm-refused.md`.
