# Rust producer-fidelity spike

A stdlib Python feasibility harness, not an exact Cargo unit producer or a
build/reuse go/no-go test. All code and tests are local to this directory. It
does not change repository manifests, install tools, run Nix, or fetch
dependencies. Use installed Cargo/rustc binaries; rustup proxies are rejected to
avoid implicit toolchain installation. Local inspection found Cargo **1.95.0**.

## Cheap phase

From the worktree containing this script:

```sh
python3 -B scripts/rust-unit-spike/spike.py probe \
  --repo /home/pvl/spaces/abird/src/z \
  --lockfile /home/pvl/spaces/abird/src/z/Cargo.lock \
  --output-dir tmp/rust-unit-spike/abird \
  --metadata-no-deps --timeout 10
```

Omit `--metadata-no-deps` for help/version probes only. `--cargo` and `--rustc`
select installed local executables. An alternate `--lockfile` can be
fingerprinted in help-only mode; execution refuses alternate lockfiles because
stable Cargo cannot select them. The allowed metadata command is exactly
offline, locked, no-deps, format version 1. `--locked` asserts lock
immutability; the harness also compares lock and manifest SHA-256 before/after.
No-deps does **not** validate the lock's full resolved graph.

All generated output and writable Cargo state must be below this script's
checkout-root `tmp/`, even when the inspected repo is elsewhere. Choose a
**nonexistent output directory for every run**; the harness creates it
exclusively with private, fresh Cargo home/target/temp directories. Existing
output directories are rejected, not merged or cleaned: stale Cargo config,
artifacts, runtime files and nested symlinks are never reused. Output paths
escaping `tmp/` or containing symlinks are rejected.

Each child has a wall time bound and a 2 MiB combined stdout/stderr limit.
Overflow/timeout records incomplete evidence. On **every exit**, including
success, exceptions and keyboard interrupts, the harness sends SIGKILL to the
child's process group, bounds direct-child reaping to one additional second, and
closes both output pipes. This also kills ordinary background descendants whose
parent exited successfully. Rust-related ambient variables/wrappers are removed.
Default cheap-phase timeout is 10 seconds per child; maximum is 30.

`report.json` contains binary, manifest, lock and local config fingerprints,
version/help transcripts, advertised stable capabilities, probe status and
explicit fidelity gaps. The whole lock/resolution digest is recorded as plan
freshness (`plan_freshness`), **not** canonical Unit derivation identity.
Equivalent registry units across isolated lockfiles must converge when their
actual unit inputs are equivalent. JSON uses sorted keys with no timestamps or
durations; identical observed inputs, paths and command results serialize
identically. Failures and timeouts remain visible, not promoted into successful
observations. Publication writes a fresh exclusive temporary file and atomically
replaces `report.json`, never truncating an existing report inode. A report
hardlinked to any inspected manifest, lock, binary or local config is rejected
before execution and again before publication. Failed publication removes its
temporary file and leaves any prior report intact; exceptions/interrupts do not
publish partial reports. A zero exit status means a report was written with
unchanged lock and manifest, **not** that a producer qualified. Clean generated
output when evidence is no longer needed.

## Stable limitations and existing mechanisms

- Cargo metadata is **package-level**. No-deps gives workspace definitions, not
  a dependency closure. Even full metadata's resolved package nodes/features
  cannot establish resolver-separated host/target/build/dev compilation-unit
  edges.
- Stable JSON `compiler-artifact` features describe emitted artifacts. Artifact
  target kinds/profile data do not prove a complete unit inventory, precise
  roles, or typed edges; a successful build alone cannot close this gap.
- `build-script-executed` gives some outputs (such as cfg/env/link data), not
  the complete native inputs, rerun state, execution environment and effects
  required for exact build-script fidelity.
- Local `cargo build --help` advertises `--unit-graph` as **unstable**. The
  `cargo -Z help` probe describes nightly-only flags. This harness never invokes
  a unit graph or claims it is available on stable Cargo. Nightly/unstable
  experiments require a separate authorization and capture design.
- Inspected `lib/flake/pkg-helper.nix` already uses Crane `cargoArtifacts`,
  `buildDepsOnly`, artifact archive inheritance and multi-parent joins. These
  are reuse mechanisms, **not** an exact crate/unit capture contract. No
  explicit compiler-message/unit-graph/rustc-wrapper collector was found in the
  inspected checkout's `lib/`, `pkgs/`, or `scripts/`.
- Ancestor Cargo config, source/native input closure, sysroot, and ambient
  non-Rust environment are not fully attested. Fingerprints bind observations to
  selected inputs but do not establish reproducible compilation identity.

Every real report emits `producer.qualified: false`, `decision: not_proven`,
zero eligible exact descriptors, and separate unknown/exact-false feature, role,
edge and build-script facts. These are evidence gaps, **not** a proven no-go.

## Next authorization gate (not run during this task)

First authorize a bounded offline compilation on an **isolated disposable repo**
under `tmp/`, choosing a representative package and provisioning an approved
local dependency cache/vendor configuration without network. Inspect its Cargo
config/build scripts first: compilation executes repository/native code which
can write outside Cargo's target directory or initiate network access; this
harness is **not a sandbox**. Process-group cleanup cannot contain descendants
that deliberately leave the group/session, prevent writes elsewhere, or survive
the harness itself being forcibly killed. It reaps its direct child; orphan
zombie reaping remains the external supervisor/init's responsibility. Require
external process/resource containment and network denial for that authorization.
The build phase rejects repositories outside this checkout's `tmp/`.

The separate, implemented stage requires an explicit expensive opt-in:

```sh
python3 -B scripts/rust-unit-spike/spike.py capture-build \
  --repo tmp/rust-unit-spike/isolated-repo --package PACKAGE \
  --output-dir tmp/rust-unit-spike/build --timeout 600 \
  --allow-expensive-build
```

This runs only offline locked `cargo build`, single-job, JSON messages, with a
bounded timeout/output size. Its isolated Cargo home starts empty: missing
cached sources cause an honest Cargo offline failure, never a Cargo fetch.
Transcripts and message counts are diagnostic artifact evidence only; even a
successful authorized build **still cannot qualify the producer**.

After that, separately authorize design/implementation of a trusted exact
capture adapter and fixture matrix: split host/target features, proc macros,
build-script compile/run units and inputs/effects, normal/build/dev edges,
profiles/rustflags, and cross-target contexts. Require complete captures plus
compilation and reuse validation before any producer or graph-design go/no-go
claim.

## Synthetic contract tests

```sh
python3 -B -m unittest discover -s scripts/rust-unit-spike/tests -v
```

Synthetic fixtures exercise fail-closed descriptor eligibility and equality only
when **every** descriptor field explicitly carries exact status and a value.
Missing/observed/unknown fields, incomplete edges and build-script input
identities are rejected, never filled from package metadata or target-kind
guesses. Toolchain/config context, package/source identity, target, role/triple,
features, profile, ordered rustflags, typed dependency descriptor edges and
build-script applicability/build-time input identities participate in identity.
The canonical context explicitly excludes the whole lock stamp. Synthetic tests
prove differing plan/capsule/lock stamps leave equivalent units' keys unchanged.
Descriptor inputs are deep-snapshotted before normalization and hashing, so
later nested input mutations cannot change the returned descriptor behind its
hash. Features/target kinds and edge ordering are normalized; rustflag order is
preserved. Divergent actual exact unit inputs must produce different keys.

Build-script result references carry `status: build_time_input` with synthetic
input and result-producer identities. They model build-time inputs to downstream
units, **not evaluation-captured output values**; the schema rejects the
previous executed/output-digest shape. No no-IFD or child-composition evaluation
is attempted by this harness; those checks remain owned by the main agent.

`descriptor()` is a synthetic schema exercise, **not a trusted producer
adapter**; caller-supplied exact labels are not verified evidence. Even its
synthetic results carry `producer_qualified: false`. Tests mock Cargo for
runner/report cases, including atomic publication, hardlink rejection, fresh
state and malformed JSON message reasons. Non-object messages and missing or
non-string `reason` values count as malformed evidence; unknown string reasons
remain forward-compatible and never qualify the producer. JSON decoder syntax,
nesting-limit and integer-conversion failures count as malformed message lines
or `invalid_json` metadata, allowing incomplete reports to be published. These
error catches cover decoding only, not downstream programming errors.

Process tests use only short-lived, self-bounded Python dummy processes for
success/failure orphaning, interrupts, exceptions, timeout and output limits.
Linux tests temporarily adopt orphans as a subreaper to verify killing and reap
all descendants without leaving zombies; those tests are skipped elsewhere. Test
temporary files stay under checkout-root `tmp/` and are removed by the tests. No
Cargo/Nix build is needed or performed by tests. The main agent owns
coordination and durable `.agents/docs` updates outside this directory.
