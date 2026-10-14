# Rust packaging

This directory owns Rust package construction, Cargo/Crane source and cache
contracts, toolchain selection, standalone exports, mirror tooling and optional
qualification support. Package definitions continue to use the stable
`lib/flake/pkg-helper.nix` facade or their injected package stack.

## Layout

- `default.nix` implements the Rust constructors using shared package
  operations.
- `closures.nix`, `compile-context.nix` and `member-bases.nix` implement
  declared workspace planning, compiler contexts and member composition.
- `toolchain.nix` selects immutable toolchains and the corresponding Crane
  library.
- `export.nix`, `mirror.nix` and `mirror-sources.nix` define standalone exports
  and the revision-owned mirror support boundary.
- `trunk/` contains the WASM bootstrap resource used by the Trunk constructor.
- `tests/` owns generic Rust checks and fixtures. Root check names are
  unchanged; repository product integration stays in
  `lib/flake/tests/<topology>/`.
- [mirror/](mirror/README.md) owns the mirror CLI and its adjacent trusted Nix
  validator. This is export tooling; ordinary package construction does not run
  it.
- [qualification/](qualification/README.md) owns reusable optional fixture,
  acceptance and VM support. Product/repository scenarios live in
  [scripts/qualification/rust/](../../../scripts/qualification/rust/README.md)
  and inject their recipes; the generic library never selects them.

The general commands in `scripts/` maintain the repository: formatting, linting,
updates, secrets and operational wrappers. They remain there because their owner
is the repository, rather than the reusable Rust library. Repository
qualification scenarios also belong to scripts because they bind real products
and workspace assumptions. No compatibility directory is left under
`scripts/rust-fabric/` or at the former flat `lib/flake/rust-*.nix` paths.

## Validation

Run source layout and mirror tests from the repository root:

```sh
python3 -B -m unittest discover -s lib/flake/rust/tests -p 'test_*.py' -v
python3 -B -m unittest discover -s lib/flake/rust/mirror/tests \
  -p 'test_rust_mirror.py' -v
```

The full mirror suite creates temporary Git objects and can evaluate cached Nix
exports; it does not compile packages. `MetadataRAMTests` is the isolated
in-memory subset. Qualification Python discovery must include both patterns:

```sh
python3 -B -m unittest discover -s lib/flake/rust/qualification \
  -p 'test_*.py' -v
python3 -B -m unittest discover -s lib/flake/rust/qualification \
  -p 'freshness*test.py' -v
```

Ordinary `test_*.py` discovery misses `freshness_test.py`. Qualification tests
include filesystem and mocked subprocess checks. Real VM qualification remains
an explicit, optional operation, using 16 CPUs and 16 GiB for new lanes.

## Evidence and compatibility

The language layout preserves the public helper API and build semantics. New
mirrors use the current revision's source paths and exclude tests, mirror CLI
resources and optional qualification from runtime support. Mirror CLI flags and
provenance tags are unchanged; mirrors must be generated from a full immutable
commit with the matching source contract.

Historical receipts, source pins and retired execution artifacts retain their
original layout and bytes. Replaying those pins uses their corresponding
archived support and tooling, rather than substituting current files. Moving
code does not renew runtime qualification, enable adoption or change regular
Cargo policy.
