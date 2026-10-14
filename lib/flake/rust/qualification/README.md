# Rust foundation — qualification support

## NixOS VM matrix

All new VM lanes use 16 CPUs / 16 GiB by explicit human instruction.
Repository-specific manager and 24-member scenarios live in
[scripts/qualification/rust/](../../../../scripts/qualification/rust/README.md).
The shared matrix accepts caller-supplied recipes; it does not select a product
or repository. Dependency producers must remain in `excludedOutputs` even when
their source/vendor/tool inputs are selected. Tested Cargo outputs are never
image seeds.

Scoped foundation qualification and integration are complete at the source pins
recorded in the
[main handoff](../../../../.agents/docs/notes/tooling/rust-foundation-main-handoff-2026-10-12.md).
That handoff is authoritative for results, supported contexts, custody and
regeneration. The
[design contract](../../../../.agents/docs/design-patterns/rust-foundation.md)
defines compatibility and admission rules.

Regular-Cargo manager qualification passed six required cases in both repos at
Pvl `d82fa09bed7678484638a3de2cb3f84b5aed2c04` and Abird
`544e18818a3456a8858a04db5ff54bd57183e3c2`. Cache export/restore preserved exact
NAR identity with compilation disabled; warm cases compiled two workspace and
zero external crates. Independent byte equality remained optional FAIL.
Committed manager mirrors and integration passed at those pins. The 24-member
evaluation admits 20 native contexts and declines four; it does not establish
24-product execution, ARM runtime or universal payback.

Abird's newer upstream `Cargo.lock.nix` policy is unsupported by optional
closure/base/mirror routes; the ordinary package route retains its source
replacement. Earlier qualification does not certify that newer policy. Current
code lives under `lib/flake/rust/`; historical replay uses its archived matching
layout and tooling. Broad adoption remains separate.

Required qualification uses regular Cargo and defaults to
`checkDeterminism = false`. It validates an unchanged Nix cache hit, a local
binary-cache export/delete/restore with compilation disabled, ordinary warm
recompilation retaining dependency bases, changed warm and independent changed
fresh builds. Runtime checks can assert an observable source edit. Cache
transport must preserve the exported NAR exactly; independently compiled NAR
differences are reported as optional reproducibility diagnostics.

Set `checkDeterminism = true` explicitly to require independent-build byte
equality and Nix `--rebuild`. Project/dependency reproducibility is outside the
foundation's guarantee. Required correctness, locality, mirror/parity,
platform/cost and review gates are unchanged. The human's fresh Nix release
workflow remains separate from this warm-cache qualification.

The optional repository `pvl/manager-patched-vm.nix` entrypoint selects a
qualification-only Cargo 1.95.0 backport of upstream PR #16691.
`patched-cargo.nix` builds the exact upstream ordering change using the original
Nixpkgs recipe; `cargo-order-check.nix` checks independent binary dep-info bytes
and source-edit invalidation. The repository `pvl/manager-vm.nix` route defaults
to regular Cargo. The patched entrypoint defaults to `checkDeterminism = true`.
These tests are explicit imports and are not registered in regular
systems/root-flake checks. Patched validation must be labeled separately from
unpatched cache determinism.

`vm-test.nix` / `vm_test.py` implement the stock NixOS test-framework matrix.
`smoke-vm.nix` / `smoke-recipes.nix` exercise sandboxing and independent stores;
`recipe-vm.nix` evaluates an explicit `recipeFile` for both host and guest; the
caller supplies the `preservedFiles` inventory. Repository wrappers own product
paths and expectations. `recipe-seeds.nix` selects actual declared inputs from
explicit producer and extra-input lists, without tested Cargo outputs. Generic
modules never import the repository wrappers.

The
[VM note](../../../../.agents/docs/notes/tooling/rust-foundation-nixos-vm-2026-10.md)
contains run instructions and separately labeled reuse and optional determinism
results. Earlier regular-Cargo forced-warm equality failed; patched Cargo fixed
that first failure, then changed warm/fresh equality failed. Those diagnostics
retain their original scope.

## Historical fixture and product results

The support below retains its original source pins and acceptance limits.
Historical deferred gates do not override the main handoff's completed results.
Old execution packets are retired; this directory provides optional
qualification support. Historical fixture results do not establish current
manager Cargo reuse.

**Bounded Pvl baseline, four-member edits and Cargo freshness acceptance
passed.** All native evidence referenced here belongs to the Pvl foundation
worktree; copying these generic modules to Abird does not qualify Abird
products/platforms/cost. Actual product acceptance covers only Pvl's host-agent
singleton, not the24-member gate. Historical preparation/deferred statements
below describe their original gates. These isolated modules are not root checks,
production package routes, an executor or an adoption/default switch. No
Cargo/native build, capture, provider/network fetch or publication is authorized
by importing them. Producer remains `qualified = false`,
`decision = not_proven`.

## Historical prerequisite batching and product acceptance

`prerequisite_batches.select_batches(pending, graph, valid)` is a pure helper:
from authenticated schema4/pending-output metadata, select only original
`cargo-package-*` unpacks whose exact source FOD/descriptors/dependency outputs
are already valid. Preserve all selected outputs in sorted batches of at most16.
It neither runs commands nor reads/writes files, plans Cargo units, changes
recipes or replaces Nix/Cargo/Crane. The contained caller realizes each group
with ordinary Nix, verifies every output, then realizes the unchanged acceptance
target under one nonrenewable aggregate deadline. Failed commands stop; no retry
or per-batch resource/time renewal. Full-lock vendor/sources and package-owned
compiler/options/wrappers stay unchanged. This is opt-in qualification support,
not a root build route/default or execution grant.

2026-10-05 original Pvl host-agent `productSemantic` **passed** with existing
Cargo/rustc1.95.0:17groups/270remaining original unpacks then originalk3h^out,
228.308s aggregate under300s/oneCPU/2GiBAS+cgroup/swap0. All three actual
version/describe/missing cases passed and eight-path runtimeclosure verified. No
downloads/compression/allocator knobs or toolchain changes. Old unbatched
attempt reached exactAScap; batched run sampledNixVM belowcap. This demonstrates
a bounded qualification route, not allocator-cause attribution, general savings,
exact Cargo/external reuse or mirror/Abird/platform qualification. Private cache
retained for separately admitted next work, grant fullycharged/closed. Evidence:
active plan phase `20261005T172141Z-batched-product-native`.

## Workspace and scope

`fixture.py` materializes a fresh owned directory beneath repository `tmp/`:

- `leaf`: labelled normal/build/macro/dev features;
- `branch`: normal leaf dependency;
- `app`: normal branch, build helper, proc macro and dev helper;
- `build-helper`, `macro`, `dev-helper`: their own leaf feature requirements;
- `peer`: unrelated component.

Actual std-only Rust source exercises a checked-in build-script input, consumed
build environment, deterministic macro output and dev-helper tests. Resolver 2
separates normal target features from build/proc-macro host features; host
build/macro features unify, and tests add the target dev feature. There are no
registry/git dependencies, profiles or `default-members`.

The local lock v4 is generated from this fixture's declared dependency union,
not from a claimed resolved unit graph. Keep the older role-capture fixture
unchanged: its default-member/dev-only assertions are unsuitable for subset
priming.

Variants:

| Variant         | Change                              | Intended observation                                  |
| --------------- | ----------------------------------- | ----------------------------------------------------- |
| `baseline`      | None                                | Construction and later semantic parity                |
| `rust-edit`     | Leaf implementation/expected output | Bases unchanged; relevant members change; peer stable |
| `manifest-edit` | Unused leaf feature                 | Containing source closures change; peer stable        |
| `lock-edit`     | Valid lock comment                  | Full-lock/base identities change globally             |

Lock comments do **not** imply different Cargo resolution. Cached Crane
normalizes its parsed vendor input, so this variant may keep the vendor
derivation identical while lock/source/base paths change. Do not weaken that
honest distinction into a claim that every raw lock edit changes every vendor
output.

## Code-only validation

Run from the retained worktree. Fixture directories must be fresh; the generator
never overwrites an existing destination. Materialization is owned staging
followed by atomic no-replace publication, with failed staging cleaned.

```sh
python3 -B -m unittest discover -s lib/flake/rust/qualification \
  -p 'test_*.py' -q
mkdir -p tmp/g4-qualification
for variant in baseline rust-edit manifest-edit lock-edit; do
  python3 -B lib/flake/rust/qualification/fixture.py \
    --variant "$variant" --output "tmp/g4-qualification/$variant"
done
```

Evaluate specific modules directly, using **explicit existing** cached source
paths—no `path:` refs, flake fetching, staging or IFD. For this worktree's
cached baseline, the package-set argument is:

```nix
import /nix/store/3a5jzlyfgc4imvkf2qibs5yb35nf0lz1-source {
  system = "x86_64-linux";
  overlays = [(final: _: {
    craneLib = import /nix/store/rkz006xkgqrn2dav1274ggmqf00p9w46-source {
      pkgs = final;
    };
  })];
}
```

Use it as `PKGS_EXPR` in this shell invocation, with the paths explicitly
supplied:

```sh
nix eval --impure --offline --option allow-import-from-derivation false \
  --json --expr "
    import ./lib/flake/rust/qualification/eval.nix {
      pkgs = ($PKGS_EXPR);
      src = ./tmp/g4-qualification/baseline;
      variants = {
        rustEdit = ./tmp/g4-qualification/rust-edit;
        manifestEdit = ./tmp/g4-qualification/manifest-edit;
        lockEdit = ./tmp/g4-qualification/lock-edit;
      };
    }
  "
```

This evaluates construction only. Test bare/actual-toolchain-overlay package
sets on both Linux architectures; evaluation of ARM derivations does not run ARM
code. After successful local validation, remove only the fixture directory you
own.

## Explicit target interface

`import ./default.nix { pkgs = pkgs; src = materializedPath; }` returns:

- `buildTargets.baseline`, `.member`: actual helper consumers;
- `buildTargets.baseline-test`, `.member-test`: their owned tests;
- `buildTargets.base-<member>`: genuine contextual bases for the seven members;
- `acceptanceTargets.archiveChain`: bounded actual Cargo-target archive
  name/link inspection for base chains and the member layer;
- `acceptanceTargets.semantic`: compare baseline/member binary outputs with
  fixture-owned `expected-output.txt` and each other;
- `compiledInputs`: actual source/lock/vendor/stdenv/parent/output observations;
- `diagnostics`: declared topology and explicit unproven/deferred evidence
  labels.

The private acceptance module receives the already-constructed handles. There is
no recursive re-import, producer override, injected sentinel or fabricated log.
The pure `archiveObservationValid` helper tests observation schema/negative
cases; it never admits compiler artifacts or substitutes for actual archive
inspection.

Expected output is an imported Nix source input, not a repository-local path a
sandboxed builder would accidentally need. Archive inspection lists names only,
without extracting repositories or reading fingerprint payloads. It bounds entry
count, listing bytes and chain depth, rejects cycles/foreign archive links and
unsafe names, and checks actual `.prev` links against selected parents.

## Forward member invalidation interface

Import `./invalidation.nix` with `pkgs` and exactly four materialized `sources`:
`baseline`, `rustEdit`, `manifestEdit`, `lockEdit`. It exposes one explicit
`acceptanceTargets.memberInvalidation` target. Construction forces actual
identity/ locality/vendor/full-lock controls and fixture expectation
relationships. Metadata observations do not pull unrelated peer/check outputs
into realization.

Upon separately approved realization, four actual member-mode binaries must
match their own imported expected-output files. Rust edit must change stdout;
the unused feature declaration and raw lock comment must preserve stdout. Output
includes observed stdout files/TSV and clearly labelled constructor identity
observations. No resolved units, Cargo freshness or exact reuse certificate is
produced.

Apply `./invalidation-eval.nix` to the same `{ pkgs; sources; }` for cached
offline no-IFD checks, including negative source/expectation controls. Use
explicit import arguments as in the validation example above; neither module
realizes derivations.

This is **forward-only**: no legacy consumer route or member-to-legacy rollback.
`baseMode = "legacy"` is retired. Independent/isolated builds remain supported
via `useWorkspaceDeps = false`; default/null/union compatibility is retained,
not a proposed future migration back. Historical three-route native evidence is
retained as historical evidence, not an active interface.

## Acceptance obligations and limits

| Obligation      | Prepared now                                                          | Still deferred                               |
| --------------- | --------------------------------------------------------------------- | -------------------------------------------- |
| Strict subset   | Constructed parent identity plus actual baseline archive inheritance  | Broad native/platform acceptance             |
| Source/context  | Actual consumer toolchain/library, lock/vendor/stdenv observations    | Native effect equivalence                    |
| Semantic parity | Baseline smoke binaries and genuine dev/host feature tests passed     | Edited-variant native behavior               |
| Locality        | Forced source/manifest/lock matrix and member-only acceptance target  | Compile edited variants and compare behavior |
| Modes           | Retired legacy alias; default/null/union and isolated builds retained | Separate adoption decisions                  |
| Admission       | Peer/equal/stale/native context negative construction cases           | No artifact-use certification                |

A `.prev` link and fingerprint names show archive structure, not that Cargo
reused an artifact. Construction establishes the actual `cargoArtifacts` edge,
not dynamic extraction or Cargo freshness. Later execution must retain actual
build logs showing inheritance of the expected archives; absent logs remain
missing evidence. No fabricated marker, patched archive format or arbitrary
producer hook may fill that gap. Delta archives can replace legitimate parent
metadata.

Dependency-free behavior cannot establish external-artifact reuse, exactly-once
compilation, complete resolved units/roles/edges/effects, native/platform/cost
acceptance or producer qualification. Cargo freshness messages are
supplementary, not exact producer authority. No result here enables root or
Abird adoption.

## Historical run-preparation wording — original October 3 cutoff

The checklist below records the original separate-admission preparation, not a
new per-run approval demand. Genuine October9 forward authority later covered
necessary separately bounded original-route runs; exact current review/proof,
finite containment and the current qualification pause still apply. Consult the
comprehensive handoff in the foundation worktree. It does not authorize Git,
policy changes, adoption or private cleanup.

### Deferred run: approval and containment first

Before proposing a native invocation:

1. Select one native system and explicit target list. Do not execute ARM outputs
   on x86 or broaden to host/root/Tauri/WASM/provider contexts.
2. Read-only inspect derivations and their dependency closure. Require all
   external tooling/source prerequisites cached; report missing outputs without
   building, substituting, fetching or falling back. Pure fixture-supporting
   derivations are part of the explicitly proposed run, not permission to build
   unrelated tools. Check the complete pruned dependency graph, not just direct
   compiler/tool inputs: Crane's selected TOML writer can require uncached
   `crane-utils` tooling and crate sources behind generated Cargo.toml. The
   first pilot stopped at that gate. A separately approved writer build later
   passed; the fixture then failed before Rust on read-only generated manifest
   replacement. Source repair passed projection builds; an approved retry then
   exposed UID0/minimal-capability backend ownership behavior. Ordinary UID1000
   workers with zero capabilities and strict private-state restart probes pass.
   Subsequent same-target offline pilot passed in 26.268s: actual archive
   inheritance, exact 74-byte three-route stdout and genuine dev-feature tests.
   Std-only smoke, not exact units/freshness/external reuse/cost/adoption.
   Durable work-capsule evidence retained, private cache cleaned. Do not change
   writer/compiler, production copy semantics or relax worker privileges; see
   the indexed note.
3. Obtain separate human approval for target scope, jobs/cores, wall time,
   memory, output retention and **external containment covering Nix daemon
   builders**. Client `ulimit`, CLI timeout and `--max-jobs`/`--cores` do not
   themselves provide that containment. Disable substituters/network; abort on
   missing prerequisites.
4. Select only the approved target: baseline archive/parity or the forward
   member-only edited-variant target. Preserve complete logs and actual
   observations. Do not implicitly expand to extra tests, architectures or
   production workloads.
5. Record actual evidence/failures separately from these prepared assertions.
   Preserve original source hashes; cleanup only owned fixtures/reports.
   Integration and publication remain separate approvals.

There is intentionally no self-starting native runner or build command in the
code-only validation path.

## Bounded actual Cargo freshness replay

`freshness.nix { pkgs; src; }` exposes `manifest` and actual `buildTargets.seed`
/ `buildTargets.privateTools`. Its member consumer forces constructor
reconstruction/admission of the app seed; oldest-first archive entries bind real
parent handles, full contextual derivation recipes and the actual Crane
restoration hook. `freshness-eval.nix` takes explicit cached `pkgsPath`,
`cranePath`, `srcPath` paths and optional `system`. For pure no-IFD FILE
evaluation, create an explicit local wrapper applying those arguments, then use
`nix eval --offline --option allow-import-from-derivation false --json --file
WRAPPER`.
This does not realize outputs. Missing archive/tool outputs are an explicit
native-readiness blocker, never a fetch/build fallback.

After independent review and separate contained native admission only:

```sh
python3 -B lib/flake/rust/qualification/freshness.py \
  --manifest /absolute/evaluated-manifest.json \
  --output /absolute/repository/tmp/new-owned-output
```

The manifest is schema v1: `source`, `seed` (handle/archive/admission/recipe),
`tools` (cargo/rustc/tar/zstd executables, privateTools and operation
identities), `environment`, full `recipes`, `restoration` (kind, hook/recipe,
oldest-first bound chain) and honest `limits`. Keep the evaluated JSON and cache
admission record. Only actual `out` outputs are supported; use `DRV^out` for
separately approved realization. CLI exits 0 on pass, 1 on diagnostics; output
must not exist. Readiness errors print a JSON diagnostic without creating
output.

Four independent baseline source copies restore the admitted chain by the
reviewed Crane zstd/tar semantics with extra fail-closed entry inspection (no
links/devices/traversal). They prime app, unrelated peer and test-no-run,
observe warm baseline, apply exactly the fixture delta, then observe delta and
warm no-op. Each phase runs actual release/offline/locked/jobs=1 Cargo JSON, app
stdout and the emitted test executable. Priming is not asserted fresh. Warm
phases require actual artifact fresh flags; Rust edit requires dirty leaf/app
and fresh peer. Leaf feature sets, build-script environment effects and genuine
test success establish only the fixture's supported roles. Reused build-script
messages are not claims that the script reran.

`summary.json` retains four variant/phase observations and explicit
`exactProducer: not_proven`. Each variant has numbered argv/cwd/environment,
full-lock before/after hashes (including failing commands), raw stdout/stderr,
parsed messages, archive bindings/listings, exact delta diagnostics and copied
source snapshots. Original source mtimes/bytes, tool bytes and archive bytes are
rechecked. Unchanged copied source mtimes survive deltas. No Nix-cache, timing,
unit DAG, exact producer or cost conclusion follows. Additive JSON logging is
not identity equivalence to the original artifact recipe.

Non-native tests mock every subprocess, including the complete four-variant
protocol; they never execute Cargo, compilers or restored binaries:

```sh
python3 -B -m unittest discover -s lib/flake/rust/qualification \
  -p 'freshness*test.py' -v
```

The native writer owns containment, resource limits, aggregate deadline and
budget accounting; this script deliberately does not claim to provide them.

## Bounded warm-cache replay

`freshness.nix` constructs a manifest from actual guarded memberG4 handles and
reconstructed producer recipes, projected native context, selected tool roots,
source/hash snapshot and genuine ancestor archives. `freshness-eval.nix` accepts
explicit cached `pkgsPath`, `cranePath`, `srcPath`, `system` arguments; apply
the function before JSON serialization, offline and no IFD. This is not a root
flake validation route or `path:` source-ref escape.

`freshness.py --manifest MANIFEST --output NEW_ABSOLUTE_DIRECTORY` replays only
inside an approved contained backend with authenticated immutable
manifest/source and cached selected tool closure. It checks actual Cargo JSON
artifact fresh flags, binary/test semantics, warm no-op, Rust edit,
unused-feature manifest edit and raw-lock-comment stages, explicit
release/offline/locked/jobs1 commands, source/lock snapshots and archive/source
admission. It does not self-authorize native execution or certify exact producer
descriptors/unit-DAG/effects/savings. `freshness_test.py` has28pure
source/parser/admission controls; they are distinct from private backend
controller mocks and actual Cargo qualification.

Pvl's reviewed execution observed48commands and32app/test outputs. Warm stages
were fresh; Rust/manifest edits dirty app/test but not peer, raw-lock comment
stays fresh. AggregateG4 warm17.455s includes three pre-Cargo failures. Original
source mock overwrite restored/fixed, actual source bindings re-reviewed. Native
controller uses one serialized/durable all-remaining reservation, absolute PID1
hard deadline and trusted completion plus confirmed container absence before any
refund. Installable `DRV^out` belongs to `nix build`, not `nix-store --realise`.
Actual evidence is indexed under the Pvl implementation work capsule;
`20261003T192927Z-g4-freshness/`. Earlier semantic expectations are not
retrospectively relabelled as freshness proof.

## Explicit product semantic API (historical source-preparation wording)

The original 'not native-qualified' statement below is a preparation cutoff, not
erasure of the October5 original Pvl host-agent acceptance above. Latest
relocated Source was statically checked only; no current-module/native rerun or
manager/reuse/Abird/platform acceptance follows from relocation.

`product-acceptance.nix { pkgs; actualDrv; finalDrv; expected; }` receives
already-constructed derivations; it never imports a product constructor. It
checks actual derivation/output/store-path equality **before** serializing the
final identity and constructs `productSemantic`. The selected binary path keeps
its Nix store context. Importing or evaluating this module does not realize it.
Identity expectations belong to the caller, not to the shared runner. Nothing
registers a root check or changes any build/compiler/default setting.

`product_semantic.py` exposes
`run_acceptance(binary, final, expected, output, *, output_root=fixture.TMP_ROOT)`.
The final identity has `derivationPath`, `output`, `storePath`; only `out` is
supported. The binary must be directly under that handle's `bin/` directory.
These lexical Python checks do not authenticate an arbitrary JSON identity; Nix
binding and independently admitted immutable inputs are the trust boundary.
There is no adjacent `evaluation.json` dependency or execution on import.

The expected specification has `schemaVersion = 1`, exact `versionStdout`,
`resourceId`, distinct `missingResourceId`, `operation`, and `resourceManifest`.
The manifest is schema 1 with exactly one resource whose `data_paths` is
`["@owned-data@"]`. The runner substitutes an owned, initially absent data path
and writes the actual resource manifest in its private output stage. It runs
only version, `--json resource describe --resource ID`, and missing-resource
cases. Services programs are overridden with `/does/not/exist`; there are no
service/activation/sysctl operations or default state/data paths. Missing
resource must exit 1 with empty stdout and a JSON error naming the resource.

Every case is bounded to ten seconds and 1 MiB combined stdout/stderr while
reading pipes. Wrong versions, malformed/duplicate JSON, wrong
operation/resource or boolean status, unexpected exits, timeouts, output
overflow and state/data creation (including dangling links) fail closed. Output
parents must already exist without symlinks. Default output fence is repository
`tmp/`; the Nix builder explicitly supplies its owned build directory as
`--output-root`. Successful raw stdout/stderr, argv/cwd/exit/absence
observations, manifest and summary publish atomically without replacing a
destination. All evidence files are created relative to the opened stage
directory with exclusive, no-follow creation; pre-existing symlinks and
hardlinks cannot redirect writes. The CLI inherits that directory descriptor and
uses `/proc/self/fd/FD` paths for cwd, manifest, state and data. Ancestor/stage
bindings are checked after commands and around descriptor-relative publication.
Cleanup traverses only the opened owned stage, never a swapped absolute pathname
or its replacement. A stage moved out of the opened parent may remain empty
rather than being chased outside the owned boundary. Specification files are
bounded regular, no-follow reads. Absence observations cannot prove that data
was never read or establish arbitrary native effect equivalence.

After separate native approval only, the CLI accepts `--binary`, `--final`
(identity JSON file), `--expected` (specification JSON file), `--output`, and
optional `--output-root`. It is not a native controller, containment or budget
manager. This new module remains **not native-qualified** until an actual
separately admitted run; historical matching CLI evidence does not execute it.
Producer remains unqualified, adoption stays off.

Host-neutral source regressions, with every CLI subprocess mocked:

```sh
python3 -B -m unittest discover -s lib/flake/rust/qualification \
  -p 'test_product_semantic.py' -v
```

Apply `product-acceptance-test.nix` to explicit cached `pkgs` before offline,
no-IFD JSON evaluation. It reports `assertionsCount`, rejecting opaque out-path
metadata and mismatched actual identity triples without running any output.

### Nix path-info protocol adapter

`store_metadata.py::path_info_references` normalizes current path-keyed JSON and
legacy path-info arrays without filesystem access/execution. Strict
duplicate-key JSON parsing is required before calling it; callers must retain
queried closure / key-set agreement, registered physical checks and
reference-closure validation. Nix2.34.8's actual map caused the real-chain
runner's array-only failure after successful signed Bash-dev restoration. Pure
adapter reviewed/actualmetadata controls pass; future contained worker must bind
its bytes in the authenticated loader. Existing executed snapshots/grants remain
historical andclosed; not a Cargo freshness/signature/content/runtime
certificate.
