# Critique of Plan B ("F-cluster")

Reviewed against the live code (`lib/flake/pkg-helper.nix`, crane rev `73b9805`
at `/nix/store/7rradzysxg41b2yx7qnh2f2bw73py192-source`) and reproduced with
cargo 1.95 under `tmp/design-f/` (`reuse/`, `residual/`, `locktest2/`,
`wsfeat/`, `dfinherit/`, `resolv/`).

Verdict in one line: the **core cache argument is sound and the plan is
honest**, but the **headline shape (B0) fails the stated objective at this
repo's scale**, the plan **needlessly gives up `--locked`**, and the "signature
⇒ zero residual" lemma is a _feature_ argument that does not establish
_fingerprint/reuse_, which is what the base must satisfy.

---

## What the plan gets right (verified)

- **The L residual is real and correctly located.** Clean base
  `cargo build -p a -p b` where `b` requests `serde/rc` and `a` does not, then
  `cargo build -p a`, recompiles `serde_core` + `serde` (verified in
  `tmp/design-f/residual`). This is exactly the `syn`/`clap`/`sha2` mechanism.
- **Identical-signature co-selection really does reuse.** With `a` and `b`
  having byte-identical direct/dev tables, base
  `cargo check --all-targets -p a -p b` + `cargo build -p a -p b` +
  `cargo test -p a -p b --no-run`, then `cargo build -p a` and
  `cargo test -p a --no-run` both reported every external `Fresh` (verified in
  `tmp/design-f/reuse`). So inheriting a cluster base in the normal _and_
  dev/test domains works, `--all-targets` included.
- **`default-features` polarity is safe.** Cargo _does_ inherit
  `default-features = false` from `[workspace.dependencies]` when the member
  omits it (verified in `tmp/design-f/dfinherit`: `shared` resolves without
  `default`/`d`), so Plan B's rule "member field else workspace field else true"
  matches Cargo. Plan A's BLOCKER is genuinely avoided.
- **`.rs` locality and the `/build/cargo-workspace-source` invariant survive.**
  Crane's `mkDummySrc` launders manifests at eval time (`cleanCargoToml` +
  `writeTOML`), filters the source to `Cargo.toml`/`Cargo.lock`/`.cargo`, and
  derives the output name from the input basename; `cargoWorkspacePrePatch`
  rewrites the laundered root `members` because `crane-json2toml` emits a
  multi-line `members = [` (verified with `crane-json2toml`). A filtered cluster
  source therefore still unparks to `/build/cargo-workspace-source` and does not
  depend on `.rs` contents.
- **The duplication numbers are exact.** Package-instance closures recomputed
  from `Cargo.lock`: `{0, 65, 216, 233, 239}`, union **367**, sum **753**, ratio
  **2.052**. The plan's `~2.05×` is not a guess.
- **Correctness is grouping-independent.** The member's own `-p m` invocation
  resolves features; a bad cluster only costs recompiles. This is a genuine
  robustness advantage over Plan A.

---

## Ranked issues

### BLOCKER-1 — B0 is not a viable headline: it is a ~2.05× compile regression at the actual scale, and the plan's own decision rule rejects it

**What.** The assigned/headline shape (B0, one `buildDepsOnly` per signature
cluster) at this repo's 5 members produces 5 singleton clusters and compiles
**753 external package-instances to produce a 367-package union**. The plan's
own §11.3 rule (`Σ|C_k| ≤ 1.5·|U|`) would _not_ select B0 here; it selects B1.
So the described mechanism, taken as the deliverable, fails the hard requirement
"compile externals as few times as possible," and it is ~20–30× more extra
compiles than the L residual it removes (a handful of crates: `syn`,
`clap`/`clap_builder`, `sha2`).

**Why (evidence).** Reconstructed from `Cargo.lock`: union 367, sum 753 (matches
the plan). The plan itself writes "B0 at 5 members ≈ 753 … That is ~2.05× the
union … B0 is _not_ a compile-count win at 5." The 24-member "8–10×" is
extrapolated from a 5-member pairwise Jaccard and is unsupported (union
saturates as members grow; sum grows roughly linearly).

**Smallest correct fix.** Make **B1 (spine or chain) the baseline** and treat B0
purely as a diagnostic stage; or, until a 24-member workspace actually exists,
keep Design L and don't ship the new subsystem. Delete the "8–10×" extrapolation
or compute it from a real member set.

### BLOCKER-2 — Dropping `--locked` is unnecessary and reintroduces the silent-graph-downgrade hazard

**What.** §6 sets `baseCommon` with no `--locked`, justifying it with "the root
member list is rewritten, which can make cargo want to touch the lock." That
premise is **false**.

**Why (evidence).** On a reduced workspace (root `members = ["a"]`, `b/`
removed) with the _full_ lock, `cargo build --locked --offline -p a` succeeds
and leaves the `b` entry in `Cargo.lock` untouched (`tmp/design-f/locktest2`:
`b` count stays 1). Plain `cargo build --offline -p a` rewrites the lock and
removes `b` (count → 0). So `--locked` works fine across a rewritten member
list; dropping it is what creates the rewrite. Fact 3 says `--offline` "silently
downgrades the graph" when pins mismatch — the plan then has to lean on V4 to
catch the exact hazard it could have forbade by construction.

**Smallest correct fix.** Keep `cargoExtraArgs = "--locked --offline …"` for the
bases (the extra, unused lock entries are harmless), and downgrade the "V4 is
the second load-bearing unknown" framing.

### P1-3 — The "signature-equality lemma" proves feature equality, not reuse; reuse needs fingerprint equality, which `signature(m)` does not contain

**What.** §7.1 states "the base at index k … resolves each external to the same
feature set … so fingerprints match." Feature-set equality is necessary but not
sufficient. Cargo's `-C metadata`/fingerprint also includes `RUSTFLAGS`,
`CARGO_ENCODED_RUSTFLAGS`, profile flags, the `--cfg` set, and — critically —
the _derivation inputs_ (`nativeBuildInputs`, `buildInputs`, `env`) and the
physical vendor path. None of these appear in the §5.2 signature. §10 admits
native inputs are "not visible in the manifest" and proposes a separate
"native-input profile" key, i.e. an admission that `signature(m)` is not the
guarantee §7.1 claims.

**Why (evidence).** The plan's own §10 option (2) exists precisely because two
members with equal manifest signatures but different `-sys` build inputs will
produce/need different fingerprints; if they share a cluster, the base can only
carry one input set. V2 asserts "no `Compiling <external>`" but there is no gate
that differentially checks base vs member (`V5` checks one `default-features`
crate). The lemma is therefore a _sufficient condition for a faithful
signature_, not a construction proof.

**Smallest correct fix.** Fold `nativeInputProfile` (and any fingerprint-
relevant `env`/`RUSTFLAGS`/profile axis) into the cluster key, and make the
correctness claim "zero residual **iff** signature **and** input-profile equal";
add a V2 differential that compares `cargo tree -e features` (base selection)
against `-p m` for _every_ member, not one.

### P1-4 — Signature fidelity is unproven and silently lossy in ways that _reintroduce_ the residual

**What.** `signature(m)` is a hand-rolled projection. It omits: `git`/`rev`/
`registry`/`artifact`/`lib` fields on dependency specs; the underscore aliases
Cargo accepts (`[dev_dependencies]`, `[build_dependencies]`,
`[target.*.dev_dependencies]`); duplicate-key merge semantics; and it relies on
literal `target.<cfg>` strings. Any _under_-capture groups two members that
differ, and because grouping is the only thing guaranteeing zero residual, the
residual silently comes back (it is not caught by V9, which only checks
partition determinism).

**Why (evidence).** `builtins.fromTOML` preserves literal keys; Plan B reads
only the hyphenated tables. Cargo accepts both. A workspace that uses the
underscore form would be mis-signed. This is not exercised by the current repo,
but it falsifies the "provable zero residual" claim as a general property.

**Smallest correct fix.** Make the projection deliberately conservative: include
the raw dependency-spec table verbatim (minus known-irrelevant keys) rather than
a chosen field list; normalize underscore/hyphen table names; and gate with the
differential check from P1-3.

### P2-5 — Churn-locality table is wrong: root-manifest and lock edits invalidate _all_ cluster bases

**What.** §11.4 claims "new member → new cluster only." False. Every cluster's
`mkWorkspaceSourcePath` always keeps the root `Cargo.toml` and `Cargo.lock`, and
`mkDummySrc` launders the root manifest at eval time (it keeps
`workspace.members`/`dependencies`). Adding/removing a member changes the root
manifest _and_ the lock, so every cluster base changes. Likewise
`[workspace.dependencies]`/`[patch]` edits. Transitive path deps spread a member
manifest edit to the clusters that include that dir (e.g. an `agent` manifest
edit changes the `manager` cluster source).

**Why (evidence).** `mkWorkspaceSourcePath` (`pkg-helper.nix:67`) keeps
`Cargo.toml`/`Cargo.lock` unconditionally; `mkDummySrc` keeps
`["workspace" "members"]` in `cargoTomlConservative`. Only manifest edits to a
member that is _not_ a path-dep of the cluster are truly local.

**Smallest correct fix.** Correct the table: per-member manifest edits are
local; root manifest/lock edits are global; path-dep edits propagate along the
path graph. Don't sell B0's locality as more than that.

### P2-6 — B1 is the only viable shape, but it abandons `buildDepsOnly`, reimplements it, and its chaining-under-divergence is only argued

**What.** §6.2 must reproduce `buildDepsOnly`'s three phases because it
hard-codes `cargoArtifacts = null` (confirmed in crane's
`lib/buildDepsOnly.nix`). B1 then chains `cargoArtifacts = parent(C)` (or spine)
to get dedup. The plan estimates "realistic ≈ union + feature divergence, i.e.
L-class counts, with zero member-layer residual." At 5 members that is ~L cost
for a whole new pure-eval subsystem plus two build shapes. The spine/chain
choice, cluster ordering, and anchor selection are left as knobs/§16 open
questions.

**Why (evidence).** The plan's own §11.1: B1 bounds `367 ≤ compiles ≤ 753`,
spine ≈ 390. It also admits "medium-high" complexity. `.prev` fan-in/spine
behavior is not tested here (would need a Nix build), so V7/V2 are the only
evidence.

**Smallest correct fix.** Prototype _B1-singletons_ first (migration step 2) and
require V2/V7 to demonstrate cross-base reuse before building the cluster/spine
machinery; if B1-singletons don't beat L on churn+residual, stop.

### P2-7 — `mkCargoArtifactsJoin` is used even for a single internal dependency

**What.** §6.3:
`if dependencyMemberLayers == [] then clusterBase else
mkCargoArtifactsJoin { deps = [clusterBase] ++ dependencyMemberLayers; }`.
With one internal dep this materialises a full-archive join. The existing L code
(`pkg-helper.nix:2384-2395`) special-cases `length == 1` and just uses the
layer.

**Why.** `mkCargoArtifactsJoin` is an extra derivation and a full `.tar.zst`;
unnecessary per member for the repo's single `manager→agent` edge. The plan's
own §9 says "keep fan-in rare and shallow."

**Smallest correct fix.**
`if builtins.length dependencyMemberLayers <= 1 then
(head or clusterBase) else join`.

### P2-8 — Native-check and build inputs are not in the cluster key; base `doCheck` can fail or mis-fingerprint

**What.** The base runs `cargo test --no-run` (necessary to prime dev units),
which compiles dev-deps. Dev-deps that need native build inputs must have them
in the _base_. §10 keeps `nativeCheckInputs` on the member layer and proposes a
separate native-input profile, but the signature (§5.2) and the B1 phase code do
not include it. Members whose dev-deps require inputs the base lacks will fail
in the base's check phase, and members whose normal deps need different inputs
cannot share a base safely.

**Why (evidence).** crane `buildDepsOnly` sets `doCheck = true` and
`cargoCheckExtraArgs = "--all-targets"`, and
`checkPhaseCargoCommand = cargo
test --no-run`; `mkSharedRustDepsBase`
deliberately "takes no per-package attrs (`nativeBuildInputs`, `env`, …)"
(`pkg-helper.nix:176`). Plan B must not silently regress this seam.

**Smallest correct fix.** Include the native-input/profile in the cluster key
(§10 option 2) and add the missing `cargo test`-input surface to the base; keep
runtime-only `nativeCheckInputs` on the member layer.

### NOTE-9 — B0/B1 bases omit `CRANE_BUILD_DEPS_ONLY`

`buildDepsOnly` exports `CRANE_BUILD_DEPS_ONLY = 1`; the B1 `mkCargoDerivation`
code (§6.2) does not. If any crate/hook keys off it, B0 and B1 bases fingerprint
differently. Set it explicitly in B1 for parity.

### NOTE-10 — `cargo fmt` / `cargo metadata` / lock handling are fine, contrary to Plan A's problems

Because the plan never synthesises a crate, `cargoFmt`/`cargoClippy`/the
`buildPackage` install path see the real filtered workspace and the shared
vendor. The cluster filter + `prePatch` do not break `cargo fmt` or
`cargo metadata`; they only reduce the workspace, which `cargo` accepts. No
action.

### NOTE-11 — Glob expansion, hello-rust, bins-only, platform gating

The `builtins.readDir` glob-expansion and per-host `meta.platforms` filtering
are reasonable but unbuilt and untested; `hello-rust` (empty closure) is a
trivial base, fine; multi-bin members (`nats-wrecking-ball`) are handled by
`mkDummySrc` bin stubbing. These are implementation risks, not design flaws.

---

## Direct answers to the attack brief

- **Is the lemma sound / counterexample?** For a _faithfully projected_,
  identical signature, co-selecting two members does not change any external's
  resolution, so the base reuses in `-p m` — I could not falsify that with
  cargo. But the lemma as written (`signature(m)` of §5.2) is **not** a
  guarantee: it ignores fingerprint inputs (native inputs/env/profile) and
  several dependency-spec fields, and Cargo's workspace-global resolver means
  edition-based resolver differences are not the counterexample (per-package
  `resolver` is ignored: `tmp/design-f/resolv`). The reproducible counterexample
  class is therefore _signature under-capture_, not identical seeds.
- **Does a `-p cluster` base reuse in `-p m` given dev/test and
  `--all-targets`?** Yes, verified: `cargo test --no-run` units are `Fresh`
  after the base's three phases (`tmp/design-f/reuse`).
- **Duplication and 2× / 8–10×:** 2.05× at 5 is exact and unacceptable as the
  baseline; the 24-member extrapolation is unsupported.
- **B0 churn locality:** genuine for non-path-dep member manifests, false for
  root/lock/workspace-dep edits and for path-dep propagation.
- **Fingerprint/vendor/lock/dummy source/`fmt`/`metadata`:** shared vendor and
  `/build/cargo-workspace-source` survive the filter; `cargo fmt`/`metadata` are
  fine; the lock is where the plan makes an avoidable mistake (`--locked`).
