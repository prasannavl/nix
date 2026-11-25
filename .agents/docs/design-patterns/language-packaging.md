# Language packaging ownership

Package authors use the bound `ab` API curated by `ab/core/default.nix`, not the
internal `pkg-helper.nix`. Portable implementations live under
`ab/core/packaging/`:

| Owner                       | Responsibility                                                                            |
| --------------------------- | ----------------------------------------------------------------------------------------- |
| `rust/`                     | Cargo/Crane constructors, planning, toolchains, exports, Trunk, mirrors and qualification |
| `go/`, `nodejs/`, `python/` | Native build and check operations and language-specific resolver policy                   |
| `deno/`                     | Deno toolchain resolution                                                                 |
| `shell/`                    | Script packages and formatter/check operations                                            |

Language implementations receive shared operations explicitly and contribute
disjoint operations to the internal helper. Do not route by project discovery,
normalize manifests, or select named products in the portable library. Use
ordinary Nixpkgs builders unless the package needs a
[toolchain selection contract](language-toolchains.md).

## Composition

`core.project` and `core.packageScope` give root and child builds a coherent
recursive `pkgs`/`callPackage` and a core-only `ab`. `lib/project.nix` binds
this repository's source root and formatter config. The package's `default.nix`
declares sibling package dependencies once with `ab.package.withDeps`; neither
child flake wrappers nor the publication manifest restate the graph. See
[package project boundaries](package-project-boundaries.md).

The Rust exporter calls the original constructors with source-scoped `ab.build`
operations **and** a `withDeps` rebound to the same scope, so siblings get the
same build policy. Preserve omitted arguments, explicit overrides (including
supported `null`) and laziness. Ordinary repository lock policy is separate from
optional closure/base/mirror admission.

## Tools, tests and source boundaries

- A script belongs to the feature it implements, not to its interpreter. Rust
  mirror generation and its trusted validator live in `rust/mirror/`; reusable
  optional qualification lives in `rust/qualification/`.
  `rust/mirror-sources.nix` declares the revision-owned support tree and its
  exclusions. Preserve effective source roots, executable modes and VM support
  inputs when relocating resources.
- Product scenarios under `lib/tests/qualification/rust/` inject recipes,
  preserved source paths and seed handles. PVL's optional patched-Cargo lane
  stays there; it is not a production overlay. Shared code never imports
  repository scenarios or product source.
- Keep portable tests with their implementation. Repository integration uses
  `lib/tests/repository/`; PVL identity assertions enter shared assembly through
  `lib/repo-checks.nix` and the bound `ab.repo.checks`. `scripts/` is for
  repository commands, not product qualification fixtures.
- On extraction, compare the public API, actual package/check identities and
  exported check names; exercise root discovery and source exclusions as well as
  the builds. Update active callers, not dated receipts or immutable pins.
  Replay historical qualification with its pinned layout; do not add
  compatibility wrappers for old paths.
