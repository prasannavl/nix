# Rust producer qualification — bounded fixture capture

## Authority and baseline

The human approved the proposed first capture: one dependency-free role fixture,
offline, one Cargo job, maximum 300 seconds and 2 GiB address space. This is not
permission for wider Abird/provider/cross builds, nightly installation or
adoption of the unit-DAG. Foundation baseline: signed `d17ffe53`; preparation:
`9480ac28`. Capture preparation continued in
`worktrees/rust-fabric-foundation-20261001` without changing primary trees,
committing or pushing. The subsequent human request explicitly authorizes
porting **all** foundation, update-helper and fixture/test changes to Pvl
`master` and the local `abird` remote repository's `master`, then continuing
remaining implementation in the retained worktree. It does not request a GitHub
push or unrelated upstream synchronization. Existing dirty documentation must be
preserved; Abird needs a compatibility port rather than a blind Pvl
repository-identity overwrite.

## Fixture and predeclared expectations

The existing harness's durable fixture is
`scripts/rust-unit-spike/tests/fixtures/unit-roles/`:

- Resolver 2, five local packages, no external dependencies and a static v4
  lock.
- Target app → shared library (`target-only`), normal edge.
- App build dependency → build helper → shared library (`host-build`).
- App proc macro → shared library (`host-macro`); host features may unify.
- App dev dependency → dev helper → shared library (`dev-only`), deliberately
  **not** compiled by the selected `cargo build --package role-app`.
- Build script reads the checked-in `input.txt`, emits a rerun declaration and
  `ROLE_INPUT`, which the app consumes. It performs no writes, subprocesses or
  network operations. The proc macro emits a fixed constant expression.
- Compile-time assertions reject target/host feature leakage and unexpected
  macro/build-helper values. The README records these expectations before
  capture.

The fixture does not prove test-mode dev units or cross-target roles. Native
host and target share a triple in this run. Do not turn the predeclared
expectations into guessed producer labels or infer a complete graph from emitted
artifacts.

## Contained execution

The reviewed fixture was copied to a disposable checkout-root `tmp/` directory.
Bubblewrap mounted only `/nix/store`, the harness subtree and copied fixture
read-only, plus a dedicated writable state directory. No repository root, home
secrets or `data/secrets` directory was mounted. Separate user/PID/network
namespaces, `--new-session`, `--die-with-parent`, dropped capabilities, private
`/proc`/`/dev` and tmpfs `/tmp` bound process/filesystem/network effects.

An empty constructed environment supplied only PATH, private HOME, locale,
bytecode suppression and `RAYON_NUM_THREADS=1`. Harness Cargo
home/target/runtime state started empty. An outer 300-second timeout with a
three-second kill grace and `prlimit --as=2147483648 --core=0` applied to the
sandbox and descendants; the Cargo command explicitly used
`--offline --locked --jobs 1`.

The first launcher attempt stopped before Cargo: resolving Nix's `timeout`
symlink changed its invocation name to the multicall `coreutils` binary, which
rejected timeout flags. Preserve invocation basenames for multicall executables;
only the installed Cargo/rustc selections need the harness's resolved identity.
The corrected launcher performed **one actual build capture** under the same
bounds, without adding retries or widening compilation scope.

## Observations

Installed tools, no fetches: Cargo 1.95.0, commit
`f2d3ce0bd7f24a49f8f72d9000448f8838c4e850`; rustc 1.95.0, commit
`59807616e1fa2540724bfbac14d7976d7e4a3860`, LLVM 21.1.8. Both report
`x86_64-unknown-linux-gnu`. Cargo is the installed immutable Nix-store binary;
rustc is its installed Nix wrapper. These observations are not complete
compiler, sysroot or native-input attestation.

- Sandbox/harness return code 0; authorized build status `ok`, code 0.
- Cargo reported `dev` profile completion in 0.98 seconds. This is an observed
  fixture duration, not a general build-performance measurement.
- Six `compiler-artifact` messages, one `build-script-executed`, no malformed
  message lines; Cargo `build-finished.success = true`.
- The shared library emitted feature sets `host-build + host-macro` and
  `target-only`, with all artifact messages `fresh = false`.
- The build helper, proc macro, build-script compile target and app appeared.
  The dev helper and `dev-only` feature did not.
- Build-script message contained `ROLE_INPUT=role-input-v1`, no emitted cfgs,
  linked libraries or linked paths. This is an output observation, not complete
  build-script input/environment/effect attestation.
- Manifest/lock fingerprints and hashes of **all 15 fixture files** remained
  unchanged. The source was read-only throughout compilation.
- `producer.qualified = false`, `decision = not_proven`, zero eligible exact
  descriptors. Feature completeness, roles, typed edges and build-script
  fidelity remain unknown. Six artifact messages are not a claim of six exact
  units.

Successful raw reports, binaries and temporary launch state are removed after
summarizing them here. The fixture remains available for later explicitly
approved capture/producer regression work. Static tests validate fixture
manifest/lock semantics without invoking Cargo or compiling in CI.

Closeout validation: all 56 spike/fixture tests (49 existing + 7 new) and all
145 support tests pass. Fixture Rustfmt checks, Markdown formatting and diff
whitespace checks pass. No production Nix wiring changed, so the foundation's
previous no-IFD assertions were not redundantly rerun. Phase edits were
initially left unstaged and uncommitted in the same isolated worktree. The later
all-changes integration request authorizes a local checkpoint before porting;
producer qualification and expensive-build gates remain unchanged.

## Remaining implementation, in dependency order

### Exact Rust producer gate

The harness is still an artifact-evidence collector. A trusted pinned capture
adapter must describe every compilation unit's features, host/target role,
normal/build/dev/proc-macro edges, profile/ordered flags, native environment and
build-script compile/run inputs/effects. Then prove actual compile parity,
cross-capsule identity/reuse, intentional divergence and fail-closed handling.
Whole-lock/plan stamps stay outside unit identity. Stable artifact observations
alone do not close this gate. The remaining-implementation request authorizes
code-only producer and planning work; new compilation/capture runs, nightly
installation and provider fetches still require separate bounded permission.

### Rust executor/cache composition

Conditional unit-DAG adoption still needs the production capsule/ledger schema,
freshness checks, lazy per-unit derivation emitter, executor/assembly,
build-time input/codegen wiring and diagnostics. No such fabric is implemented
by this foundation. Preserve the package/native fallback for unsupported
capsules.

The established G4+M path remains available without exact-unit adoption: add the
pure closure/component planner and diagnostics, explicit `base` seam and
`baseMode = member|union|legacy`, real per-member closure bases with the shared
full-lock vendor, genuine closure-subset inheritance, locality/reuse/rollback
proofs and the measured 24-member cost gate. Existing Design L bases are not
already the G4 per-member implementation.

### Retained wrappers, mirrors and adoption

Keep the hand-maintained compatibility wrappers and package-owned defaults.
Independent mirrors require the revision-based generator, complete helper import
closure (including `rust-toolchain.nix`), standalone builder/export contract,
`externalPackagesFor` adoption and freshness/standalone/derivation-parity gates.
No routing JSON or wrapper retirement is reintroduced. Tier-2 standalone-library
extraction remains later than the first layout-preserving mirror.

### Abird and real integration acceptance

Port the reviewed shared foundation/Design L or selected final implementation to
Abird, with local identity checks/composition. Its existing 24-member shape,
platform/native requirements, isolated workspaces, wasm and Tauri frontend edge
must be preserved. Do not blindly enable a broad unfiltered union. Measure
actual store/evaluation/build cost before changing cache defaults. Run real
dependency reuse, toolchain-provider, cross/wasm, full-root/module and Tauri
acceptance; fixture/cheap assertion success does not replace those gates.

### Multi-ecosystem and external first-party fabric

After a qualified Rust core, implement the generic ledger/shard/edge/executor
contracts and ecosystem adapters with their own fidelity/demotion gates. Planned
ordering: Go/Deno, Node (including Deno's Node-tree needs), Python wheels then
guarded sdists, and C++ introspection/native fallback. Model
frontend/wasm/codegen as explicit compile or build-time inputs. Add
provider/export/regeneration contracts, generic mirrors and reachable pinned
external repositories. Equal release refs alone do not guarantee equal effective
build contracts or sharing.

## Authority references

- `rust-fabric-foundation-2026-10.md`: current decisions and foundation history.
- `../../plans/rust-build-graph-final-2026-09.md`: consolidated Rust G4+M plan.
- `../../plans/g4-base-locality-2026-09.md`: closure/cache/default-flip gates.
- `../../plans/dual-mode-rust-build-graph-2026-09.md`: mirror/adoption contract.
- `../../plans/multi-ecosystem-build-fabric-2026-09.md`: generic
  fabric/adapters.
- `../../plans/first-party-external-repo-integration-2026-09.md`:
  provider/export integration models and policy.
