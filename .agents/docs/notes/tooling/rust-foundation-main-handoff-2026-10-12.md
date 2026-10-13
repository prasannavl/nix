# Rust foundation: current handoff

Updated 2026-10-13. This file is synchronized byte-for-byte across the dedicated
Pvl qualification worktree and the Pvl and Abird main worktrees. The
qualification was **explicitly resumed by the human on 2026-10-12** with
preapproval for actions needed to validate and finish implementation. The prior
pause remains historical. All original acceptance, review, finite-scope,
fresh-custody and no-replay gates remain binding.

## Three-tree layout

- **Qualification and result custody:**\
  `/home/pvl/src/nix/worktrees/rust-fabric-foundation-20261001` (**R**). This is
  the only destination for qualification work, current run sources, receipts,
  and raw qualification events. Keep the current M21 baseline and all spent
  M22/M23 and now M24 Sources and results here; select fresh work only in R.
- **Pvl agent handoff only:** `/home/pvl/src/nix`.
- **Abird agent handoff only:** `/home/pvl/spaces/abird/src/z`.
- The Abird implementation candidate is
  `/home/pvl/spaces/abird/src/z/worktrees/rust-fabric-g4-port-20261003` (**A**).
  Pvl qualification does not establish Abird parity or acceptance.

The handoff and design contract are kept in each of the three destinations. The
main worktrees contain no copied qualification receipts, raw event stream, run
capsule, or history archive. Do not copy those back. When a result changes,
update this handoff and the R work README, then copy this exact file to both
main-worktree paths. The current R raw events remain the detailed authority for
qualifying work.

## Current truth

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

The main warm-build gate is still open. M21 manager/version passed, but M22
original warm and M23 retention native failed; all original qualification gates
remain. Semantic-v1 pure74 passed; both semantic reader cases closed UNKNOWN_API
without results and are spent. M24 sandbox native is CLOSED FAILED at the first
prerequisite; no causal or production fix is proved.

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

Use four decisive cases with the existing harness: fresh sandbox S0 baseline,
unchanged S0 forced warm rebuild, controlled member-source change S1 with warm
cache, and independent fresh S1. For the last pair, identical declared inputs
and recipes differ only in cache availability. Compare derivation and ordinary
compilation frontiers, output/NAR hashes and installed behavior. Matching
derivations alone does not prove byte equality. Archive-reader work is closed.

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

Stat9 serialization: retain Python integer `st_mtime_ns`/`st_ctime_ns` when
writing inventories. A Python JSON to JavaScript to JSON roundtrip rounded
Source89 supplemental inventory timestamps; the unissued v1 was retained and a
fresh directly serialized v2 authenticated before execution. Do not treat
rounded numbers as exact stat9. Caller/program bytes were unchanged.

Actual pure74 report: 2,885 bytes, SHA256
`bbb1e57925d80a2a1ab4cdfa1000a9ffcc76134c7640ae8dd806c6106caa92a2`. This is
closed Source/RAM acceptance, not a semantic runtime result.

M23's separately labelled retention diagnostic is now **CLOSED FAILED**, exit 1,
after fresh current capture, genuine QA4, final12, actual Source89 v2 both
modes, genuine original17 and the reviewed seven-stage chain. Its complete
ordinary log is 3,510 bytes/31 lines, SHA256
`8bcfadbba59f2e7d3ac705e1265d054313aed287e07fb9b94b6264693740708a`: two
workspace Compiling lines (`abird-host-agent` and `abird-host-manager`), zero
external compilations and one Finished line. Nix rejected differing output bytes
and bound the exact original selected derivation, expected output and newly
retained `.check` output through its complete mismatch diagnostic. This
establishes neither successful warm acceptance nor archive/payload causality.

BODY30 is CLOSED, fully charged, result SUCCESS_CURRENT_MEMBER_ONLY with
nativeOperations 0 and retryAllowed false. Native300 is fully charged and
closed, retryAllowed false; helper20 remains inside300. CargoFresh remains
not_observed; provenanceQualified and requiredGoalMet are false. The early
worker wire is required_build_failed/chain, errorKind not_observed and
codeBindingStatus keys_populated_unverified. Caller exit 1 has outputValidated
true, cleanupFailed false and directChildWaitReturned true. Runner
containerAbsent is true; outer independent containerAbsenceProven and
wholeHostReapingProven remain false. The current outcome authority is
`20261012T142500Z-manager23-retention-warm-mismatch-closed.md` in R. Spent
scopes and failed commands cannot supply a retry, refund or fresh authority.

M22's original forced warm case is **CLOSED FAILED**, exit 1, after the fully
reviewed current Source/control/custody/admission pipeline and original
seven-stage execution. BODY30 passed and is spent; helper20 passed inside the
fully charged, closed native300 scope. Cargo finished, but Nix rejected the
required forced rebuild because an output differed. The following normal
packaging/version step did not establish acceptance. No retry or refund is
available from M22.

Its complete ordinary log is 3,351 bytes/30 lines, untruncated, SHA256
`170a1fb13635d86e595763b150042c3ed9a2d2ad120fdc3fe28d3f8f63b15dad`. There were
two workspace Compiling lines, one Finished line, zero external dependency
compilation lines and no Rust compiler failure diagnostic. This is bounded
observed dependency compilation reuse. It does not establish successful warm
acceptance, per-dependency Fresh, deterministic archive equality or full
qualification. The worker wire is required_build_failed/chain, errorKind
not_observed, codeBindingStatus keys_populated_unverified, requiredGoalMet
false, CargoFresh not_observed and provenanceQualified false.

Direct child waits returned, caller output was validated and cleanupFailed was
false. Runner containerAbsent is true; outer independent container absence and
whole-host reaping remain unproved. The authoritative closed outcome is
`20261012T121748Z-manager22-original-warm-rebuild-mismatch-closed.md` in R. The
115900 preparation event remains immutable at its earlier runtime-unissued
cutoff. Current M22 peer/receipts/log and all spent commands stay in R only.

M21's original manager build and installed version `0.1.0` remain PASS. Its
complete ordinary log recorded zero external and two workspace compilation
lines; the two steps took about 62 seconds and 0.15 seconds. The actual full
receipt and eight observed completed-native rows remain the authenticated
baseline. The human-authorized 14 CPUs/16 GiB do not qualify the original 1
CPU/2 GiB cost case; CargoFresh remains not_observed.

M22 preparation completed once-only prior-envelope regression v2 (28 checks),
fresh Source20 normal/optimized (20 each), Source45/Code18/37 roles, current-ref
capture, the warm program-schema regression (14 checks), genuine independent QA4
normal/optimized (133 each), complete final12/literal review, Source89
normal/optimized (89 each), and the genuine closed17-field program peer. These
are scoped Source/fixture results, not substitutes for failed runtime
acceptance.

M23 retention diagnostic Source preparation was selected as
`rust-foundation-manager23-diag-20261012`. New controls v3 passed all 60 checks
once, exit 0/empty stderr, with a genuine independent current Source peer. A
preceding closed v2 attempt failed in its RAM wrapper because the copied worker
tail lacked its original local `valid` set; v3 supplies fresh `valid` and
`qualified` formal RAM sets without changing the original tail. These results
attest scoped Source ingress and RAM behavior, not bootstrap library coverage,
generic process-tree read assurance or runtime qualification. Current Source
preparation authority is
`20261012T125000Z-manager23-retention-source-controls-reviewed.md` in R.

M23 static setup passed once with 52 outputs. Fresh Source20 normal/optimized
passed 20 tests each, with 318,298 real Source ingress and 273,913 RAM reread
bytes per mode. All four exact current controls and five genuine independent
helper/workspace peers are issued. Source45/manifest37/Code18 publication passed
once, preserving six dynamic MAIN_REQUIRED hashes. Quiet current-ref capture
then closed once with 53,873,313 reserved bytes and unchanged protected Source7,
head/master/index. Genuine QA4 is 80,212 bytes, SHA256
`221558dc3331ec40e3aa1bf470f35e28ae636a542714d1a5e617253244880562`. Final12
publication closed once with 591,759 Source requests and exact actual
body/map/literal agreement with independent RAM projections; observer headroom
is 20 bytes and BODY Source payload is 100,492/131,072 bytes. The immutable
134905 current-capture/pure-control and 141341 final-source/native-selection
events remain authoritative at their earlier cutoffs.

The first Source89 shell attempt closed outer exit 127 before actual controls:
Main's empty environment lacked `cat` for the frozen BOOT command substitution.
It remains frozen/spent. Fresh independently reviewed direct-argv v2 routes kept
the exact BOOT, original Source25 caps and both modes. Actual normal/O89 each
passed once, exit 0/empty stderr, with 19,094,744 read bytes and identical named
checks. The genuine original closed17 peer is 4,597 bytes, SHA256
`651b060742dd4717b623049f87f63311a3fc2ca1a870c4a234507d382009ee81`. Those closed
Source results preceded the failed M23 chain; they establish no runtime PASS or
general bootstrap library/process-tree read assurance.

The diagnostic added only Nix `--keep-failed` on the exact original required
forced warm step, retaining `--rebuild` and all original build and receipt
semantics. Main then executed the earlier separately reviewed exact
plan/log-bound V3 two-output comparator once. It immediately CLOSED exit 1/empty
stderr, `CLOSED_ARCHIVE_MONITOR_REFUSAL`. Aggregate stdout is 113 bytes, SHA256
`875408604ffcf20e5f71c461222077145982c91d1d04c9a22d83bb9b3d317df1`; owned opaque
child stdout and monitor receipt were empty. Source25 is fully spent; no
accepted artifact comparison or artifact-read assurance was issued by V3, and no
payload-access/causal claim follows from its empty outputs. That earlier
authority is
`20261012T143200Z-manager23-bound-artifact-monitor-refusal-closed.md` in R.

A distinct independently authenticated public Python probe then closed once,
exit 0/empty stderr. Its four isolation flags were all 1; its sole Python
environment key was `PYTHONNOUSERSITE`, which the original controller's deny
predicate rejects. Exact public wrapper ELF analysis establishes
`putenv(PYTHONNOUSERSITE)` followed by `execv` of its original underlying Python
target. The unchanged mode0 monitor allows only the initial exec, so the wrapped
monitor child has a second-exec blocker as well. These prove deterministic
prelaunch compatibility defects, not the exact first stage of opaque V3 failure,
exclusion of earlier failures or any archive cause. Public Source authority is
`20261012T144200Z-manager23-public-python-bootstrap-compatibility-proved.md`.

V6 closed exact original underlying ELF/isolation/stdlib context and full
Main/independent controller Source/caller review, with
originalQfilter/fourflags/ direct wrapper-target/opaque stage diagnostics.
Paired opaque79module/57Sourcefile context matches, relevant stdlib equivalence
without global startup certificate. Monitor/caps/private two-root Stage A stayed
unchanged. V6 produced bounded comparison above; old V3 remains spent/no replay.
Actual fields/rootcause and original warm acceptance remain unproved. The
separate synthetic archive-order fixture is frozen unissued because complete
environment/bootstrap read assurance and hard process-tree CPU accounting are
unresolved. It is not a prerequisite for the retention diagnostic.

Synthetic timestamp or ordering investigations under unchanged Crane hooks may
show possible mechanisms, but they do not identify the cause of M22's runtime
refusal. The transport Source mounts all eight original native roots read-only
from the authenticated M21 prior root, rehashes them before host launch and in
the guest, and does not reserialize their compiled artifact payloads. The
381-root cache copier separately preserves opaque payloads and seals newly
copied metadata to epoch 1. Deterministic warm archive equality and the
production-path correction remain unqualified. Existing Cargo/Crane hooks,
recipes, features, flags, wrappers and the required forced rebuild stay intact.

## Original design and non-negotiable acceptance

The goal is cache reuse through the existing Cargo/Crane member-package setup:
compile dependencies efficiently, reuse compatible artifacts, and limit
invalidation to the affected Rust member and its dependents. Do not add
unrelated libc or other-project investigations.

The original goals remain in force: G1 no IFD; G2 reduce repeated external
compilation; G3 source edits stay local to a member and dependents; G4 member
manifest edits stay local to that member's dependency closure and dependents
(root workspace dependencies and shared lock changes may be global); G5 a simple
package API; G6 maximal sound reuse; G7 composable, maintainable implementation;
G8 correctness and honest claims; G9 Pvl/Abird parity; G10 revision-owned
standalone package mirrors; G11 in-repository consumption of a mirror with
matching semantics and, where established, cache identity.

The selected architecture uses each member's declared source closure, one shared
full-lock vendor root, and Cargo artifact inheritance only over a verified
strict-subset dependency edge with a matching compile context. Existing Cargo,
rustc, Crane, features, flags, hooks, wrappers, constructors and package
behavior stay intact. No peer-derived feature union, pruned vendor or lock,
generated semantic stub, fabricated parent label, or permissive ownership
fallback may make a test pass. Source tests and metadata equality do not prove
runtime Cargo reuse.

Every original gate remains open until its own real result is recorded:

1. Actual manager build and installed version on the current original recipe.
2. Forced warm rebuild and real Cargo reuse evidence.
3. Peer, comment-only and member-manifest locality; compatible subset-parent
   reuse; no IFD.
4. Complete immutable mirror ownership and standalone/composed/in-repository
   parity.
5. Generic forwarding; Abird's 24-member cost measurement; supported native,
   WASM and Tauri lanes and explicit unsupported boundaries.
6. Useful payback from observed workflows, independent review, and separate
   human integration/default/adoption authority.

## Completed work, summarized

The pure member-closure/base design, shared lock/vendor policy, compile-context
checks, constructor plumbing and immutable mirror source/generator are present.
The canonical Cargo dependency-table handling fails closed on deprecated aliases
that could hide path edges. Existing Source/fixture suites, utility and CLI
acceptance completed within their recorded scopes. A 2026-10-12 M21 actual
manager/version chain passed as described above.

A cache transport candidate normalizes copied timestamp metadata to epoch 1.
M18, M22 and M23 observed zero external dependency compilations during warm
attempts, while Nix rejected differing output bytes. Synthetic timestamp/order
fixtures under unchanged Crane hooks are separate evidence of possible archive
variation, not runtime causality. Preserve M21's successful manager baseline and
the distinct failed warm results; current evidence remains only in R.

Old manager attempts, Source-only checks, review receipts, copied proof packets
and raw historical streams are not deliverable project state. Their useful
outcomes and failures are summarized here and in the compact R work README.
Historical receipt bytes cannot be recreated as historical evidence. Fresh
qualification must generate fresh source bindings, controls, custody, proofs and
receipts from current inputs; it cannot claim to reproduce an old receipt.

## Next bounded unit

1. Read current indexes, queue, canonical plan, work README and the VM note.
   Preserve the Cargo/Crane contract and all original G1-G11 acceptance gates.
2. Keep M21/M22/M23/M24 and archive-reader evidence frozen. The actual VM
   manager baseline passed but forced warm output equality failed even with
   fixed /build paths. The fresh diagnostic proves two Cargo binary dep-info
   record-order differences; historical reader work remains closed.
3. Use the human-approved optional Cargo patch. The original forced warm gate
   now passes; next inspect retained parent cache/compiler metadata variation.
   Use the existing VM matrix to validate the changed implementation with fresh
   public source snapshots, reviewed input seeds and first-refusal behavior. Do
   not spend another manager run merely to repair historical evidence retention.
4. After unchanged warm acceptance, continue changed warm versus independent
   changed fresh: exact derivations, expected compilation frontiers, output/NAR
   equality and installed behavior. Keep original cost and other qualification
   gates separate; no production adoption, commit or push follows from setup.

The VM harness uses 7 cores and 8 GiB per guest, a 300-second case deadline and
stock framework cleanup/1800-second global timeout. Image preparation and boot
are visible separately. It does not reproduce the original Podman admission,
fullstat9/read-budget/cost protocol or certify its original 1 CPU / 2 GiB gate.
Historical grants remain spent, and old qualification receipts are not copied
into the VMs.

## Regenerating qualification inputs

Start from the current implementation and recipes; do not replay archived
commands or substitute a historical receipt.

- Implementation and current R/A source:
  `/home/pvl/src/nix/worktrees/rust-fabric-foundation-20261001` and
  `/home/pvl/spaces/abird/src/z/worktrees/rust-fabric-g4-port-20261003`.
- Current qualification and mirror code: `R/scripts/rust-fabric/qualification/`
  and `R/scripts/rust-fabric/mirror/`.
- Current constructor/public-input source:
  `R/.agents/runs/rust-foundation-accounted-constructor-v12-source-20261011/`.
  Its original finite admission is frozen; inspect it as implementation context,
  not as a grant to replay.
- Authenticated M21 baseline:
  `R/.agents/runs/rust-foundation-manager21-20261012/` and its `-programs`
  sibling. Read only the exact current success receipt and its authenticated
  observed metadata through the bounded readers; preserve RAM-only handling and
  never print raw carrier values.
- Spent current M22 Source/runtime capsule:
  `R/.agents/runs/rust-foundation-manager22-warm-20261012/` and its `-programs`
  sibling. Preserve exact failed outcome/log/accounting records and all
  commands; inspect only fixed bounded public records, never private output
  roots.
- Closed M22 prior-envelope regression:
  `R/tmp/manager22-full-prior-source-20261012/`. V2 passed once; do not replay.
- Closed warm schema correction/regression Source:
  `R/tmp/manager22-warm-program-schema-source-20261012/`. Its original warm row
  projection and zero-import admission passed 14 RAM checks once; no physical
  custody was supplied by that fixture.
- Closed M23 retention diagnostic Source preparation:
  `R/tmp/manager23-retention-diagnostic-source-20261012/`. Candidate core v3
  adds only the exact diagnostic retention argv; new controls v3 passed 60
  checks once and its independent Source peer is issued. Preserve closed v2 and
  v3 evidence; do not replay controls. Bootstrap libraries were outside the
  Source-input receipt; it is not general process read assurance.
- Spent M23 static/final/native preparation and retained mismatch:
  `R/tmp/manager23-diag-preparation-20261012/`,
  `R/.agents/runs/rust-foundation-manager23-diag-20261012/` and its `-programs`
  sibling. Fresh Source/capture/controls/peers and the once-only diagnostic are
  closed. Keep actual Sources, commands, receipts and logs frozen. Old V3
  comparison closed/spent at monitor refusal. Fresh V6 closed successful bounded
  metadata/payload comparison, fields/rootcause unproved. Subsequent semantic
  reader v1/v2 both closed UNKNOWN_API/no result and spent Source25 each;
  further reader work is not selected.
- Frozen unissued synthetic archive-order Source:
  `R/tmp/manager23-archive-order-regression-20261012/`. Its declared ELF graph
  was reviewed, but complete environment/bootstrap coverage and hard aggregate
  CPU enforcement remain unresolved; no phase assurance or execution occurred.
- Current state and authority:
  `R/.agents/plans/work/2026-w40-rust-fabric-implementation/events/`. Read the
  resume, M21 pass, M22 failure, M23 Source/control/final/capture and latest
  142500 native failure, 143200 comparator-refusal and 144200 public bootstrap
  compatibility-proof, 150400 actual V6 success, semantic control/reader
  closures, M24 sandbox selection and its actual namespace-refusal outcome. Raw
  events remain authoritative over summaries. The fresh first-manager case must
  bind new current refs and reviewed environment Source; prior receipt identity
  and spent scopes stay frozen.

The original M21/M22/M23 receipts, old Source bindings and finite-grant bytes
are evidence of past events, not regeneration inputs. They are retained in R to
preserve the baseline and closed outcome. Regenerating qualification means
deriving fresh inputs from current Git refs, implementation, public recipes and
authorized current scope; then rerunning reviewed gates to create new evidence.
If required current Source or executor is missing, rebuild it from R's reviewed
implementation sources without restoring the deleted evidence collections.

## Documentation cleanup verification

The main worktrees retain the durable Cargo workspace note alongside this
handoff and the shared design contract. Removed historical proof collections are
absent, and the M21 baseline plus spent M22/M23 Sources/results remain in R. The
shared handoff, contract and canonical plan are byte-identical across the three
destinations; R retains its separate active work capsule and staged changes.

The preceding cleanup checkpoint passed documentation formatting and
Markdownlint checks. The Pvl full repository diff lint passes. Abird static
lints pass; its full repository check is blocked by the refreshed Nixpkgs
marking the configured Kanidm 1.10.4 as end-of-life. The separate Tailscale
constructor-argument mismatch was corrected in both its package and updater. No
identity-service migration or insecure package allowance was introduced. These
repository checks do not qualify Rust cache reuse. Qualification resumed through
the later explicit human instruction.

The unpublished main documentation series is consolidated into one final handoff
commit per repository. Abird's external input refresh remains a separate commit
with its Tailscale compatibility repair. Fresh successor preparation must
capture the resulting current main refs; old event commit IDs remain historical
observations, not current bindings.

## New-agent starting prompt

```text
Continue the resumed Rust foundation qualification. Use these absolute paths:
R=/home/pvl/src/nix/worktrees/rust-fabric-foundation-20261001
A=/home/pvl/spaces/abird/src/z/worktrees/rust-fabric-g4-port-20261003
Pvl main=/home/pvl/src/nix
Abird main=/home/pvl/spaces/abird/src/z

Qualification is active under explicit human validation preapproval; do not
launch any unit before reading current state and reporting remaining gates. Read each
main's AGENTS.md and .agents/docs/README.md, .agents/plans/README.md and queue.
Then read this R handoff and COMPLETELY read:
R/.agents/docs/notes/tooling/rust-foundation-next-agent-prompt-2026-10.md
R/.agents/docs/notes/tooling/rust-foundation-handoff-2026-10-11.md

Read the current R design contract, plan/work README, human resume, M21 pass,
M22 preparation and latest closed-failure event. Preserve all original G1-G11
and acceptance gates. M21 manager/version PASS; M22 forced warm CLOSED FAILED:
Cargo finished with two workspace/zero external compilations, but Nix rejected
differing output bytes. CargoFresh not_observed; provenance false. BODY30 and
native300 are spent, helper20 was inside300; do not replay any closed unit.
M23 retention controls60/static52/Source20both/genuine9/Source45+37+18,
quiet currentcapture53873313, QA4, final12, actual directargvv2 Source89both
and genuine original17 passed. The reviewed seven-stage retention diagnostic
is now CLOSED FAILED1: complete3510byte/31line log, workspaceCompile2,
external0/Finished1, exact admitted expected/retained.check mismatch join.
Native300 is fully charged/spent; CargoFresh not_observed, provenance and
requiredGoal false. Caller output validated/direct wait returned/cleanup false;
runner absence true does not prove outer absence or whole-host reaping. Read
the immutable134905/141341 cutoffs and latest142500 closed-failure event.
The sole argv delta was exact-step Nix --keep-failed. The separately reviewed
exact plan/log-bound comparator then CLOSED1/CLOSED_ARCHIVE_MONITOR_REFUSAL,
emptyerr, aggregate113bytes; childstdout+monitorreceipt empty. Source25spent,
V3 issued no accepted comparison/read assurance or causal claim. Read143200 plus144200
public Source proof: isolation flags all1, sole Python keyPYTHONNOUSERSITE is
denied; exact wrapper putenv->execv conflicts with unchanged mode0 initialexec
only. Deterministic compatibility blockers are proved, but opaqueV3 first stage,
earlier-failure exclusion and archivecause are not.
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

Semantic-v1's 74 pure controls passed once; both subsequent semantic reader
cases v1 and direct-body-v2 CLOSED FAILED at UNKNOWN_API with empty comparator
stdout. Each Source25 grant is spent, with no replay/refund. Correcting v2's
executed-code envelope did not resolve the refusal. No actual `.d` path,
metadata-field or causal result was issued; refused syscall and partial access
remain unproved. Archive-reader work is closed, with Sources/results frozen.

M24's fresh first-manager environment experiment
`rust-foundation-manager24-sandbox-20261013` is now CLOSED FAILED. Its only
worker delta was `sandbox = true`, `sandbox-build-dir = /build`, and
`sandbox-fallback = false`, testing the stable
`/build/cargo-workspace-source` assumption. The original rootless/read-only/
network-none/private-PID/cgroup boundary, narrow capabilities followed by
UID/GID1000 and capabilities0/NNP, seccomp, cache/owner/fullstat9/NAR,
registration/bridge, no-fetch/no-IFD and recipes/hooks/features/flags/wrappers
were retained. No SYS_ADMIN, unconfined seccomp or fallback was used.

M24 did not select a sandbox-capable execution environment or namespace
isolation change. The later human-authorized NixOS VM implementation and its
actual result below now determine the next work. Ordinary `build-dir = /build` fixes only the parent and still allocates a
variable temporary child path; it is not equivalent to the sandbox's `/build`.
Do not replay M24, silently disable sandboxing or reopen archive-reader work.
Only a successful fresh admitted baseline can support its fresh original forced
warm case; all warm, locality/subset, no-IFD, mirror, Abird/platform/cost/payback
and integration/adoption gates remain open.

Keep recipes, wrappers and original build/packaging/version predicates intact.
Use the completed NixOS VM setup and its current result below; select an
artifact-determinism implementation fix before another fresh matrix; do not
continue archive-reader probes. Source controls do not certify runtime reuse or
generic bootstrap/process-tree read assurance.14CPU/16GiB does not establish
original1CPU/2GiB cost. All original qualification and separate integration/
adoption gates remain open.

Rebuild fresh qualification inputs from current implementation and recipes.
Never replay historical commands or closed grants. Keep actual receipts,
runtime evidence and work products in R only. Update this same handoff in R,
then copy identical bytes to both main worktrees and keep their indexes free of
proof/event/archive copies. No push, implementation merge, activation, default
adoption, or claim of full qualification is authorized by this prompt.
```

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
