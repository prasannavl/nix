# Dual-mode / mirrored-package goals for the Rust build graph (2026-09)

New goals added to the Rust build-graph design after the REWEAVE plan.

## Goals

- **G5 (relaxed).** Repo structure and abstractions may change. The constraint
  is that the **consumption API** stays simple, intuitive, and clean (a package
  author and a consumer of a package flake should not need to know the
  machinery).
- **G10 (dual mode / mirroring).** Each `pkgs/...` package must work
  - **(a) in the monorepo**, and
  - **(b) mirrored into its own repo** as an individual package, buildable as a
    standalone flake, with `lib/flake` optionally extractable as an isolated
    library. Mirroring must require only minimal changes and must not create
    maintenance churn (no per-package divergence that has to be kept in sync by
    hand).
- **G11 (seamless replacement).** The monorepo must be able to include the
  mirrored package's flake and use it **in place of** the in-repo package, and
  merge seamlessly: the same package semantics, and ideally the same
  artifact/cache sharing.

## Why this conflicts with REWEAVE

REWEAVE and Plan A achieve compile-once by **union-forcing**: a member's
dependency features are widened to the shard/monorepo union. That makes a
package's effective feature set depend on which peers exist in the monorepo.

- A standalone mirrored build has no peers, so it resolves the package's own
  subset; the monorepo build resolves the union. The two can produce different
  binaries, so G11 "seamless merge" is not guaranteed.
- The shard base is monorepo-scoped, so an external package flake cannot reuse
  the monorepo base or contribute to it without being adopted into the
  workspace.

Composition-independent package semantics push toward **per-package canonical
resolution** (Plan B's axis), which the first council rejected on cost (~2.05x
at the current scale). The resolution must be re-derived under the new goals.

## Process

The first design council (researcher/explorer -> 3 staff engineers -> 3 critics
-> engineering manager) is being relaunched with these goals, artifacts under
`tmp/design-f2/`.

## Status

REWEAVE (`.agents/docs/plans/design-f-build-graph-2026-09.md`) is retained as
prior art but is **not sufficient as-is** for G10/G11.
