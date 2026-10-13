# Rust fabric tooling

This is the script grouping for **Rust foundation**, not a new project or a
production package route. Reorganization does not enable adoption, establish
manager/Cargo reuse, or qualify products, platforms, mirrors or cost.

The overview, mirror README and source-only layout tests are shared between R
and Abird. Each checkout retains its own qualification source; R-specific
helpers/results are not promised in Abird. Copying documentation/tests is not
Abird native acceptance or permission to run qualification.

## Owners and layout

- `mirror/rust-mirror.py` is actual implementation: generate and validate an
  immutable Git revision's declared Rust source/support scope. Its trusted
  `rust-mirror-validate.nix` stays adjacent because the generator loads it via
  `Path(__file__).with_name(...)`. Existing flags, provenance tags, constants,
  source filters and validation limits are unchanged. See
  [mirror](mirror/README.md).
- `qualification/` contains current fixture generation, Nix acceptance modules,
  pure helpers, mocked regressions and freshness/product runners. These are
  qualification support, not root checks, a production executor, a package build
  route or a default switch. Some runners execute real binaries; importing
  support or reading examples does not authorize execution. See
  [qualification](qualification/README.md).
- `tests/test_layout.py` checks source paths without importing or executing the
  candidate tools.

## Historical producer probe retirement

The former `scripts/rust-unit-spike/` feasibility/synthetic-descriptor harness
is retired from active source, including its helper tests, README and role
fixture. It is not an exact Cargo producer or a prerequisite of the selected
Cargo/Crane route. Its original working bytes and modes are preserved under:

```text
.agents/plans/work/2026-w40-rust-fabric-implementation/evidence/
  rust-foundation-20261010-tooling-cleanup/retired-producer-probe/{R,Abird}/
```

Each checkout retains its own labelled tree and pre-move SHA256/mode inventory.
Historical loaders, relative roots and example commands inside the retired tree
are intentionally unchanged; it is custody evidence, not runnable tooling from
its new location. Indexed-versus-working differences are separately retained.
There is no active compatibility shim or probe test registration.

## Tests and discovery

Run the source-only layout regression from the checkout root:

```sh
python3 -B -m unittest discover -s scripts/rust-fabric/tests -p 'test_*.py' -v
```

For a separately authorized broader test session, discover each owner
explicitly:

```sh
python3 -B -m unittest discover -s scripts/rust-fabric/qualification \
  -p 'test_*.py' -v
python3 -B -m unittest discover -s scripts/rust-fabric/qualification \
  -p 'freshness*test.py' -v
python3 -B -m unittest discover -s scripts/rust-fabric/mirror/tests \
  -p 'test_rust_mirror.py' -v
```

Ordinary `test_*.py` discovery **misses `freshness_test.py`**. Qualification
suites include filesystem and mocked subprocess tests; they are not all
RAM-only. The full mirror suite creates Git fixture objects and can evaluate
cached Nix exports. Do not run it under a no-Git/no-Nix execution boundary; its
`MetadataRAMTests` class is the isolated RAM-only subset. The reorganization
receipt records exactly which tests were actually run, not full-suite
acceptance.

## Fresh source bindings, not recycled proof

Executable paths changed, including Source7's `store_metadata.py`. Old proposals
and grants are retired and cannot serve as fresh proof for this layout. Require
new source/path bindings and independent admission before later qualification.
Preserved current-source18 archived files, historical receipts and hashes are
not rewritten. Canonical docs, indexes, plans, work summaries and events remain
MAIN-owned; Git staging cleanup is a separate MAIN decision after the manifests.
