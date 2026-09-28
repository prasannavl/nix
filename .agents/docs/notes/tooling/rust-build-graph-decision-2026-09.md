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

`lib/flake/pkg-helper.nix` passes the real filtered source as crane's explicit
`dummySrc` at `mkRustDerivation` (`2136-2138`), `mkCraneRustPackage`
(`1684-1686`), and `mkTrunkProject` (`1581-1583`). Crane uses an explicit
`dummySrc` verbatim as the build source, so the `*-deps` derivation compiles the
crate's real code and depends on the whole source tree.

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
