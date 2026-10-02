# Unit-role fixture (pre-capture expectations)

This standalone resolver-2 Cargo workspace has five local packages and no
external dependencies. The default member is `role-app`; select that package for
the isolated capture. The checked-in, manually authored version-4 `Cargo.lock`
contains only local packages. No Cargo compilation was performed while preparing
this fixture.

## Expected roles, features, and edges

- `role-app` is the target binary. Its normal edge to `role-shared` requests
  `target-only`, with default features disabled.
- `role-app` has a build edge to `role-build-helper`. That host library has a
  normal edge to `role-shared` requesting `host-build`.
- `role-app` has a normal dependency on the host proc-macro `role-macro`. That
  proc-macro has a normal edge to `role-shared` requesting `host-macro`, and
  emits a deterministic `u32` constant expression without external crates.
- Resolver 2 separates target features from build/proc-macro features. The host
  uses of `role-shared` may unify `host-build` and `host-macro`; neither host
  consumer requires those two host features to be separated.
- `role-app` declares `role-dev-helper` only as a dev dependency. That helper
  requests `dev-only` on `role-shared`. **`cargo build` does not compile the dev
  helper or activate `dev-only` through this edge.** The capture uses build, not
  test, and must not use `--workspace` or select the helper as a root.
- `role-app/build.rs` is compiled for the host and then executed. It uses the
  build helper, reads the checked-in `role-app/input.txt`, emits
  `cargo:rerun-if-changed=input.txt` and `cargo:rustc-env=ROLE_INPUT=...`. The
  app consumes that environment value with `env!`. No generated file is needed;
  fixture code performs no file writes, network access, or subprocess execution.

`role-shared` has an empty default feature set. Its role-aware modules export
small helpers. Compile-time feature-label assertions reject target/host leakage:
the target app requires exactly `target-only`; the build-script and proc-macro
consumers require their respective host labels and reject target and dev labels.
The shared library itself rejects host labels combined with `target-only` or
`dev-only`. The declared dev helper permits target/dev unification but rejects
host labels. This is a build-only fixture, not a separately validated test
configuration.

## Evidence boundaries and execution ownership

These are qualitative expectations, not proven exact compilation-unit counts or
a complete typed unit graph. Package metadata cannot prove resolver-separated
unit roles or edges. Build-script observations are **not full input attestation
or exact proof** of its environment, inputs, effects, or downstream identity.
The tiny known input and deterministic macro do not qualify an exact producer.

MAIN owns copying the fixture into disposable checkout-root `tmp/`, external
containment, network denial, capture execution, and global documentation. The
approved single offline capture is limited to one job, at most 300 seconds, and
2 GiB address space. Run neither Cargo compilation nor the capture in this
checked-in fixture directory. Compiler/Cargo outputs belong to MAIN's isolated
writable paths; any future build-script-generated file must be strictly under
`OUT_DIR`.
