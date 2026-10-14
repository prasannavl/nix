# Immutable Rust mirror implementation

`rust-mirror.py` generates a mirror from a full resolved commit object ID and
that revision's declared source/support contract, then validates exports with
adjacent `rust-mirror-validate.nix`. It is actual implementation, not merely a
qualification fixture. CLI flags, provenance tags and toolchain policy stay the
same. Canonical source paths and the support exclusions follow the language
ownership layout.

The generator still loads the validator with `with_name(...)`; move them as a
pair. Mirror tests now load the generator from
`lib/flake/rust/mirror/rust-mirror.py`, with the checkout root five ancestors
above `tests/test_rust_mirror.py`.

Test discovery, from the checkout root, for a separately authorized session:

```sh
python3 -B -m unittest discover -s lib/flake/rust/mirror/tests \
  -p 'test_rust_mirror.py' -v
```

This full suite is **not RAM-only**: `MirrorTests` creates Git fixture objects;
`CachedExportTests` can invoke Nix validation when cached inputs are available.
`MetadataRAMTests` uses opaque in-memory metadata and mocked queries only. A
successful RAM subset is not immutable-source integration or native acceptance.
No build, fetch, fixture-backend run or runtime qualification is authorized by
this README. See the [tooling overview](../README.md) for retirement and fresh
source-binding boundaries.
