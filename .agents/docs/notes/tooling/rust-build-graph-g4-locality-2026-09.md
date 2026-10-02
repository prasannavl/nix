# G4 locality requirement — Rust build graph (2026-09)

Follow-up to `rust-build-graph-dual-mode-goals-2026-09.md`.

## Requirement (operator-defined)

- **Tolerated global rebuild:** edits to the root `[workspace.dependencies]` and
  the shared `Cargo.lock` (i.e. a change in what the whole workspace resolves,
  such as a shared-dependency version bump).
- **Not tolerated:** a semantic change to **one member's `Cargo.toml`**
  invalidating the whole repo. It must invalidate only **that member's own
  external closure and its dependents** ("the affected dep's graph parent
  chain"), not unrelated members.

## Why it is global today

1. The shared base's source is **every member manifest**
   (`mkRustWorkspaceSource` over all members; the base builds `--workspace`), so
   any member manifest edit changes the base drv.
2. One shared `Cargo.lock` + vendor dir is an input to every base.
3. `buildDepsOnly` hard-codes `cargoArtifacts = null`, so a changed base drv is
   rebuilt **from scratch** -> all externals recompile; every member layer's drv
   (its `cargoArtifacts` input) changes too, so all member layers re-run.

The fix must make each base's **invalidation key equal its own resolved external
closure**, not the raw bytes of the whole workspace.

## Option space

| #  | option                                                | locality                                             | cost                            |
| -- | ----------------------------------------------------- | ---------------------------------------------------- | ------------------------------- |
| O1 | per-member bases (`-p m`, member-scoped source/lock)  | exact                                                | ~Nx                             |
| O2 | per-signature bases (share identical resolutions)     | signature granularity                                | ~2x at 5                        |
| O3 | canonical deps-workspace keyed on `U(M)`              | partial (non-`U` edits only)                         | ~1x, keeps peer-dependent union |
| O4 | shared core + exact per-unit delta DAG                | core global (ok); member-local -> delta + dependents | near-union + duplicates         |
| O5 | per-base canonical (pruned) lock                      | also localizes version bumps in the closure          | low                             |
| O6 | incremental base inheritance (previous base as input) | incremental even for one base                        | needs a pinned base input       |
| O7 | full per-unit DAG (cargo unit graph in Nix)           | ideal                                                | many derivations; IFD risk      |

Core tension: sharing externals => union resolution => peer-dependent semantics
(breaks G10/G11) **or** duplication. Share only when resolutions are provably
identical.

## Process

Scoped council launched (researcher/explorer -> engineers -> critics ->
manager); artifacts under `tmp/design-g4/`. Constraints: no IFD; preserve
G10/G11 (standalone == composed == in-repo, no widening); scalable to 24
members; simple consumption API; mirror-compatible; keep L as rollback.
