# Rust foundation

Implementation and actual evidence live only in R:
`/home/pvl/src/nix/worktrees/rust-fabric-foundation-20261001`. Active plan:
`.agents/plans/2026-w40-rust-fabric-implementation.md`. Main worktrees carry
informational routing; A remains the separately qualified Abird candidate.

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

## Current acceptance — 2026-10-13

The human made independent-build byte determinism optional. Required completion
concerns sound Nix cache reuse, Cargo dependency reuse, correct invalidation,
member locality and the original foundation goals. Project/dependency byte
reproducibility is outside the guarantee. Releases use fresh Nix builds.

Regular qualification retains regular Cargo and defaults to
`checkDeterminism = false`. It verifies an unchanged Nix cache hit, local
binary-cache export/delete/restore with builds disabled, ordinary forced warm
recompilation retaining dependency bases, changed warm and independent changed
fresh behavior. Cache transport must preserve the actual exported NAR exactly;
independent recompilation hash differences are diagnostics. Observable source
changes must produce their expected behavior. No source/fingerprint/output
normalization, compiler flag change or production Cargo overlay is selected.

Explicit `checkDeterminism = true` retains strict comparisons and `--rebuild`.
The optional patched-Cargo entrypoint defaults to that diagnostic and contains
only pinned upstream PR #16691. Removing it requires the fix in regular pinned
Cargo. Historical hash failures keep their original status and do not block
required reuse acceptance under the latest human decision.

## Current validation

- Required six-case smoke and optional strict smoke passed, including local Nix
  binary-cache transport with max-jobs=0 and no remote builders.
- Current source/real-constructor/locality/invalidation checks passed 1,004
  assertions, with 30 construction controls in the edit lane.
- Mirror generator tests passed 52 and fixture tests passed 28.
- Native four-variant member invalidation passed on regular Cargo: Rust edit
  changed stdout; manifest/lock edits preserved expected behavior. Full shared
  lock/vendor and compile contexts remain intact.
- The real regular-Cargo manager six-case matrix passed. Cache hit/restore
  compiled zero crates; both warm cases compiled 2 workspace / 0 external. The
  observable source edit appeared in warm and independent fresh builds.
  Exported/restored NARs matched exactly. Both independent compilation NAR
  comparisons differed, recorded as optional byte-determinism FAIL.
- V1's 300-second cold deadline remains CLOSED FAILED. V2 used an explicitly
  selected 450-second case limit, unchanged 1800-second framework timeout and
  original recipe/tool identities. This is scoped reuse proof, not original
  cost.

The current unit above supersedes the earlier mirror/platform work order.
Compiler metadata root-cause investigation is an optional separately selected
diagnostic. The Abird pkg-helper fallback to rustWorkspaceDeps is documented
repository policy; preserve it.

## Remaining closeout

Full foundation completion still requires current locality/subset/no-IFD,
complete immutable mirror support and standalone/composed/in-repository parity,
generic/Abird forwarding, the 24-member cost/payback measurement, supported and
unsupported platform qualification, independent review and separately approved
integration/adoption. The source/fixture results above have bounded scopes.
Nothing authorizes a default switch, staging, commit, push or deployment.

Current R events:
`20261013T050429Z-human-byte-determinism-optional-required-reuse-selected.md`
and
`20261013T051940Z-required-reuse-source-and-native-fixtures-pass-cold-deadline-v2-selected.md`,
with result
`20261013T053238Z-regular-cargo-required-reuse-matrix-pass-optional-determinism-fail.md`.
Registered manager report/logs:
`/nix/store/9d5az70yxh5zsck5lqxi79kypwg8d033-vm-test-run-rust-foundation-manager-required-reuse-v2-vm`.
M21 and historical M22/M23/M24/reader units remain retained/closed at their own
cutoffs; no replay or private receipt reconstruction.

Read `.agents/docs/notes/tooling/rust-foundation-nixos-vm-2026-10.md` for exact
sources, commands and results;
`.agents/docs/notes/tooling/rust-foundation-main-handoff-2026-10-12.md` for
complete acceptance/history/regeneration; and
`.agents/docs/design-patterns/rust-foundation.md` for the compatibility
contract.
