# Rust foundation

## Goal

Build Rust packages with Cargo and Crane while sharing reusable dependency
artifacts, limiting invalidation to the affected member and its dependents, and
supporting revision-owned standalone packages without changing their semantics.
This is the project formerly described by the historical G4/M design labels.
Those labels are not separate current projects.

The completed plan is
`.agents/plans/archive/2026/2026-w40-rust-fabric-implementation.md`. Its stable
coordination ID is retained; its readable name is **Rust foundation**.
Implementation and current integration results are in
`.agents/docs/notes/tooling/rust-foundation-main-handoff-2026-10-12.md`.

## Architecture

1. **Declared source closures.** A member uses its own sources and transitive
   in-repository path dependencies, not an unrelated peer set. The closure
   planner validates the supported manifest/path shape without IFD. Dependency
   tables use the canonical hyphenated Cargo names. Deprecated
   `build_dependencies`/`dev_dependencies` aliases fail closed at root,
   workspace, member and target scopes; ignoring an accepted Cargo alias could
   omit a path edge. Unsupported manifests keep the original package route.
2. **Member-local dependency bases.** Composition constructs bases once and
   injects them into packages. A member-manifest change may invalidate that
   member and its dependents; shared root dependencies and lock changes may be
   global.
3. **One full lock and shared vendor root.** Parent and child artifact layers
   must use the same vendor identity. Do not prune or rewrite locks/vendors to
   manufacture reuse.
4. **Genuine subset inheritance.** A parent may be reused only when its source
   closure is a genuine strict subset of the child's and their compile contexts
   agree. Reconstruct and compare producer identities; a self-issued label is
   not evidence. No peer-derived meet, union or arbitrary artifact parent.
5. **Preserved compile contexts.** Keep toolchains, profiles, features, Cargo
   configuration, flags, native inputs, constructors, hooks and wrappers intact.
   Native context support is bounded: reject unsupported shapes rather than
   silently dropping settings.
6. **Revision-owned mirrors.** Generate layout-preserving package mirrors from
   an immutable revision, including their complete declaration-owned helper
   support. Original immutable blob/tree metadata is distinct from emitted or
   pruned bytes. Dirty worktree snapshots are not production mirror revisions.
7. **Explicit composition.** A mirror can export its package constructor and
   receive the helper/base through normal composition. Name-based external
   package forwarding is an inert seam until separately qualified and adopted.

## Existing implementation surfaces

| Surface                                                                    | Responsibility                                                                                                         |
| -------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `lib/flake/rust-closures.nix`                                              | Declared source/path-dependency closure planning.                                                                      |
| `lib/flake/rust-compile-context.nix`                                       | Compile-context normalization and compatibility.                                                                       |
| `lib/flake/member-bases.nix`                                               | Composition-level base construction and subset parents.                                                                |
| `lib/flake/pkg-helper.nix`                                                 | `rustPlan`, `mkClosureBase`, `mkRustComposition`, `mkRustDerivation`, source-bound helper and explicit base injection. |
| `lib/flake/rust-export.nix`                                                | Package export/constructor contract.                                                                                   |
| `lib/flake/rust-mirror-sources.nix`, `rust-mirror.nix`                     | Mirror source/support declarations and mirror interface.                                                               |
| `scripts/rust-fabric/mirror/rust-mirror.py`                                | Immutable source inventory and mirror generation.                                                                      |
| `lib/flake/tests/`, `scripts/rust-fabric/mirror/tests/test_rust_mirror.py` | Planner, context, composition, source-scope and mirror regressions.                                                    |

Do not treat the old design documents' `component` or `legacy` selectors as the
current public API. Isolated package builds and package-owned defaults remain
supported. Follow the current implementation and its tests when specifying
arguments; this cleanup does not introduce or remove an API.

## Non-negotiable compatibility

- Regular systems retain the existing Cargo/rustc/Crane implementations. No
  custom compiler, fingerprint reimplementation, `CARGO_LOG` or `-vv` detour.
- Human-approved exception on 2026-10-13: optional qualification may use the
  exact Cargo PR #16691 ordering fix, pinned to upstream commit
  `074980c2670522e3bde8acb9a25b40510f78626c`, until the regular pinned Cargo
  includes it upstream. This exception is restricted to qualification tooling;
  no production Cargo overlay or automatic/root-flake qualification check.
  Patched producer/consumer contexts carry their actual distinct Cargo identity
  and receive freshly generated bases. Keep strict byte-equality checks when the
  optional determinism lane is explicitly selected; regular Cargo's known binary
  dep-info record-order nondeterminism is a cache reproducibility limitation,
  not demonstrated loss of runtime correctness or external dependency reuse.
  Patched qualification does not certify raw unpatched cache-archive equality.
- Preserve manager-to-agent dependencies, agent rsync support, the manager's
  check tools, makeWrapper/fleet PATH, and product `doCheck = false`.
- Preserve the utility's release/check/strict-dependency behavior.
- No fixture stripping, broad source filters, generic ownership exceptions,
  dirty-mirror fallback or root-registry fallback to make tests pass.
- Keep pure evaluation/no IFD and honest unsupported-platform boundaries.
- Standalone, composed and in-repository semantics must agree; never widen
  features based on the selected peer set.

## Acceptance criteria

Source/fixture acceptance is necessary but not sufficient. Completion requires:

1. Actual manager build and version acceptance on the original Cargo/Crane
   route.
2. Forced warm rebuild of the manager build derivation, with genuine Cargo reuse
   evidence. Version/output/NAR equality alone does not establish reuse.
3. Peer, comment and member-manifest locality; genuine subset-parent reuse; no
   IFD.
4. Complete immutable mirror support and standalone/composed/in-repository
   parity.
5. Generic and Abird forwarding, the 24-member cost measurement, and explicit
   platform qualification, including unsupported lanes.
6. Independently reviewed integration and any separately authorized adoption.

Human decision on 2026-10-13: independent-build byte determinism is optional.
Required acceptance concerns reusable Nix outputs/binary caches, reusable Cargo
dependency artifacts, correct invalidation and the original G1–G11 goals above.
Project/dependency build reproducibility is not guaranteed by this foundation.
Compare cache transport bytes exactly: exporting and restoring the same output
must preserve its NAR identity. Independent compilation may produce different
NARs without failing required reuse qualification. Record those differences as
diagnostics; do not erase fingerprints, strip producer artifacts or claim
determinism. Successful version checks alone do not establish safe reuse:
require observable source-change behavior and actual compilation frontiers.

Regular qualification uses regular Cargo with `checkDeterminism = false`.
Optional `checkDeterminism = true` retains strict independent-output comparisons
and Nix `--rebuild`; the optional patched-Cargo entrypoint defaults to that
lane. Releases use fresh Nix builds as the human-selected release workflow;
release builds do not replace the locality, compatibility, cache transport or
invalidation gates. Integration and adoption remain separately authorized.

Qualification resource decision on 2026-10-13: all new VM lanes, smoke and
optional diagnostics use 16 CPUs and 16 GiB RAM. The historical 1 CPU / 2 GiB
measurement target is superseded by this explicit human instruction. Preserve
resource labels on earlier results and state measured workload scope; do not
extrapolate a selected manager comparison to every workspace product.

Do not enable a broad default or claim savings before these gates pass.

## History and excluded scope

The initial Design L shared workspace base, Design F/REWEAVE union proposal,
Design M dual-mode mirror seam, and G4 closure-base proposal were compared and
adjudicated into the architecture above. The selected design keeps each member's
own source closure, one shared full-lock vendor, and inheritance only along a
genuine closure-subset edge with matching compile context.

Rejected alternatives include peer-derived feature unions, per-node pruned
vendors/locks, arbitrary parent labels, semantic stub rewrites as the current
path, compiler/fingerprint reimplementation, and generic ownership fallbacks.
The detailed rationale and original G1–G11 acceptance are retained in the closed
canonical plan, done capsule public events and qualification cutoff.

The core, mirrors and optional qualification tooling are integrated in both main
worktrees. The completed plan, public events and GC-rooted current evidence are
retained in their done capsules. Original R/A worktrees retain unmerged
historical staging and private execution artifacts. Historical receipt bytes are
not recreated; new runs produce fresh evidence.
