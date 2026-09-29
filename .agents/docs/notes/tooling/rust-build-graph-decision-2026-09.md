# Rust Build Graph Decision (2026-09)

Decision log for the repo-wide Rust build/caching redesign. The full design,
comparison, and migration seams live in
`.agents/docs/plans/rust-workspace-build-graph-2026-09.md`.

## Decision

- Implement **Design L** first: one laundered workspace source, one shared
  dependency base, layered member builds, crane `.prev` joins for internal
  dependencies.
- Keep **Design F** (demand-set dependency DAG with generated group stubs) as
  the future end state, reached through the same seams.
- **No IFD** is a hard prerequisite.
- Optimize for the repo state: the plan is a function of manifests, lock,
  toolchain, and target, and may rewire on change.

## Root cause recorded

At the pre-fix revision (`391df360`), `lib/flake/pkg-helper.nix` passed the real
filtered source as crane's explicit `dummySrc`: `mkRustDerivation` and
`mkTrunkProject` used `dummySrc = buildSrc`, and `mkCraneRustPackage` used
`dummySrc = attrs.src` only when `attrs.src` is a fetched derivation. Crane uses
an explicit `dummySrc` verbatim as the build source, so the `*-deps` derivation
compiled the crate's real code and depended on the whole source tree.
(`mkCraneRustPackage`'s fetched-source shape is unchanged, since dummifying a
derivation would require IFD.)

Observed on 2026-09-28:

- Four distinct `cargo-workspace-source` and four distinct `*-deps-*.drv`
  derivations across the four `mkRustDerivation` workspace packages.
- `abird-host-manager-deps` runs
  `cargo check --all-targets -p
  abird-host-manager`,
  `cargo build -p abird-host-manager`, and `cargo test
  --no-run`, against
  `src = ...-cargo-workspace-source`.
- Editing `pkgs/tools/abird-host-manager/src/progress.rs` changes the
  `abird-host-manager-deps` derivation path, so a source edit does rebuild the
  dependency artifact today. This contradicts the caching claim in
  `.agents/docs/notes/tooling/cargo-workspace-2026-04.md`, which now carries a
  correction.

## User constraints captured

- Every dependency, in-repo or external, compiles once repo-wide.
- Only the minimal change unit rebuilds during a project compile.
- Keep repo structure and abstractions (`mkRustDerivation`, per-package
  `default.nix`, `packages.nix` composition, checks/passthru wiring).
- No IFD.
- Feature/manifest changes may rewire the DAG; per-state optimization is
  intended.
- End state is the clean demand-set DAG (`deps-workspace`, `deps-pkg-<x>`,
  `deps-a`, ..., then project source).

## Follow-up

- Land L0/L1 (dummy-source fix, shared source and base, layered members) with
  the no-IFD and source-invariance validations from the plan.
- Add the pure-eval planner as a diagnostic before promoting it to Design F.

## Implementation status (Design L1, branch `agent/rust-build-graph-20260929`)

Implemented in `lib/flake/pkg-helper.nix` plus the `abird-host-manager` wiring:

- One `.rs`-independent shared external-dependency base (`abird-rust-workspace`,
  `--workspace` over a `mkDummySrc` of the whole workspace).
- Per-member artifacts-only `memberLayer` (`craneLib.cargoBuild`) that compiles
  the member once; the deployed `buildPackage` inherits it, so build artifacts
  stay out of the runtime closure.
- In-repo edges via `internalDeps`; each dependency's `passthru.projectDir` is
  auto-unioned into the member source. `mkCargoArtifactsJoin` covers fan-in.
- `abird-host-agent`'s transfer test now gets `rsync` through
  `nativeCheckInputs`.
- W8 landed: the legacy/rollback paths dummy their source from a path source, so
  `useWorkspaceDeps = false` no longer reintroduces the source-invalidation
  defect.

Measured:

- The shared base drv is byte-stable across member `.rs` edits; only the edited
  member's drv changes.
- The member layer keeps build artifacts out of the deployed package: the
  interim shape that published artifacts (`exportCargoArtifacts = true`)
  measured 528 MB for `abird-host-agent`, while the final shape — like the
  pre-change package — is ~54 MB and references no dependency archive.
- `abird-host-agent` compiles once (its member layer); the manager reuses it
  (`Compiling abird-host-agent` = 0).
- No-IFD eval succeeds for all members and the isolated package; the standalone
  child-flake build of `abird-host-manager` still works.

Provenance (commands):

- Base invariance: `nix eval --raw .#<member>.drvPath` and
  `nix derivation show -r .#<member> | jq -r '.derivations|keys[]' | grep
  abird-rust-workspace`,
  before and after appending a line to a member `.rs` (then revert).
- Closure: `nix path-info -S .#abird-host-agent` and
  `nix path-info -r .#abird-host-agent | grep -c abird-rust-workspace`.
- Reuse: `nix build --no-link -L .#abird-host-manager` and grep the log for
  `Compiling abird-host-agent` (expected 0).

Residual (measured, partially deferred): two kinds of feature-driven recompiles.
Transitive union — the base unions features from other members' graphs, so `syn`
is built with `extra-traits`/`fold`/`visit`/`visit-mut` and a narrower build
recompiles it and its dependents; only Design F's per-demand groups fix this.
Direct divergence — members disagree on a shared dependency's own features
(`clap` is `derive,env` for agent/manager but `derive` only for
bridge/wrecking), which `[workspace.dependencies]` normalization (W10) could
remove.
