# Plan B for Design F — **F-cluster**

> One dependency base per **feature signature**, built from **real member
> selections** (`cargo build -p …`), with **zero synthetic crates**. Member
> layers inherit the base whose selection is _identical_ to their own, so the
> Design L residual disappears by construction; grouping members with identical
> signatures deduplicates; optional inheritance chaining controls the
> duplication that per-cluster bases otherwise create.

Status: design only (no implementation). Alternative to Plan A ("F-union") and
to the landed Design L. Supersedes nothing; the L seams are reused.

- Repo under study: `/home/pvl/src/nix` (5 members, 372 locked packages).
- Hard requirements: no IFD, `.rs` edits stay local, public API unchanged
  (`pkgHelper.mkRustDerivation { projectDir; … }`), scalable to 24 members.
- Landed baseline: `mkSharedRustDepsBase` (`lib/flake/pkg-helper.nix:179-195`)
  and `memberLayer` (`pkg-helper.nix:2400-2411`).

---

## 1. What this plan is, in one paragraph

Partition the workspace members by the **feature signature** their manifests
request (the only thing an evaluator can know exactly without reimplementing
Cargo). For each partition cell (a _cluster_) build a `buildDepsOnly`-shaped
dependency base whose selection is `-p m₁ -p m₂ …` — the **real** packages, not
generated stubs — using a `.rs`-free dummy source filtered to exactly those
members. A member's `memberLayer` inherits its cluster base and still runs
`cargo build -p m`; because the base was resolved with an identical signature,
Cargo reuses every external and no residual recompile occurs. No synthetic
manifest ever exists, so `default-features = false` polarity is exact,
`cargo
fmt`/`cargo metadata` see a valid workspace, and correctness never
depends on the grouping heuristic — grouping is a pure performance decision.

---

## 2. Why L leaves a residual, and why Plan A trades it for worse problems

### 2.1 The L residual

L builds one base with `--offline --workspace` (the union of every member's
resolution) and each member with `--offline -p m` (that member's resolution).
Cargo unifies features only over the packages _selected in one invocation_, so
the base resolves externals with the workspace union and the member resolves a
subset. Where they differ, Cargo recompiles in the member layer:

- **transitive union**: `syn` is built in the base with `extra-traits/fold/…`
  (pulled by another member) and recompiled narrower in a member that needs
  less;
- **direct divergence**: `clap` is `derive,env` for agent/manager but `derive`
  for bridge/wrecking, so bridge/wrecking recompile `clap`/`clap_builder`.

L also has **no dep-manifest churn locality**: the base dummy source includes
every member manifest, so editing any `Cargo.toml` rebuilds the single base and
every external.

### 2.2 Why not the synthetic aggregate (Plan A)

Plan A adds one generated `crane-union` member and runs every layer as
`-p m -p crane-union`, so Cargo is forced to compute the global union and the
single `--workspace` base matches. That forces correctness through synthesis,
which brings the failure modes the Plan A critique already recorded:

1. **BLOCKER — `default-features` polarity.** One aggregate manifest cannot
   represent "member X disables defaults, member Y enables them". The repo
   already exercises this: `reqwest` and `ssh-key` are
   `default-features =
   false` in `[workspace.dependencies]`. An aggregate
   that omits the flag silently widens X.
2. **P1 — no churn locality.** The global `--workspace` base still rebuilds all
   externals on any dependency-manifest change; that is the reason F exists.
3. **P1 — silent lock downgrade / `--offline` rewrite** on a source containing
   lock-absent aggregate packages.
4. **P1 — `cargo fmt` / `cargo metadata` run without `--offline`** on a source
   that contains the aggregate, so they must tolerate the synthetic lock state.
5. **P2 — the aggregate is global**, so editing one member manifest re-runs
   every member layer.

Plan B removes the blocker by _not synthesizing anything_: the base is a real
subset of the real workspace.

---

## 3. Core insight: separate correctness from grouping

The critical observation that makes Plan B safe is:

> **A dependency base is only a cache. A member build always resolves its own
> real manifest. If the base's selection differs from the member's resolution,
> Cargo simply recompiles the mismatches — it never widens or narrows the
> member.**

Therefore:

- **Correctness** comes from Cargo and the member's own `-p m` invocation. It
  never depends on the planner, the grouping, or the base.
- **Grouping** is a pure optimization: it decides which members share a cache. A
  wrong grouping costs compile time, never correctness.
- **Zero residual** is obtained exactly when the base's selection resolves each
  external to the same feature set as the member. The safe way to guarantee that
  is to co-select members whose requests are identical.

This is the opposite of Plan A, where correctness _does_ depend on the generated
aggregate faithfully representing the union.

---

## 4. Architecture

```
                     pure eval (no IFD)
root Cargo.toml + member Cargo.toml + Cargo.lock
                     │
                     ▼
           rust-workspace planner
           ├─ member seeds (normal/build/dev/target, workspace-resolved)
           ├─ signature(m)  ── equality ⇒ identical resolution
           ├─ clusters = members grouped by signature
           └─ sourceDirs(cluster) = members ∪ transitive path deps
                     │
      ┌──────────────┴───────────────────────────────┐
      ▼                                              ▼
cluster bases                                member layers (unchanged API)
base(C) = buildDepsOnly{ dummy(clusterSrc C); -p C; }
      │                                              │
      │   optional spine / chain (inheritance)       │
      └──────────────► cargoArtifacts ──────────────►┘
                                              + internal-dep layers (join)
                                                     │
                                                     ▼
                                              buildPackage / checks
```

Two module boundaries, mirroring the Design F document:

- `lib/flake/rust-workspace.nix` (**new**, pure): file contents → plan. No
  `pkgs`, no crane, no derivations.
- `lib/flake/pkg-helper.nix` (**modified**): consumes the plan and emits
  sources, bases, layers, packages, checks. Public API unchanged.

Two build shapes, both **stub-free**:

- **B0 — independent cluster bases** (the assigned baseline): `buildDepsOnly`
  per cluster. Exact, simple, duplicates shared externals.
- **B1 — chained / spine cluster bases** (recommended at scale): each cluster
  base inherits parent artifacts (`mkCargoDerivation`, since `buildDepsOnly`
  hard-codes `cargoArtifacts = null`) while still resolving its exact `-p`
  selection. Near-L dedup, still zero member residual.

---

## 5. The planner: signatures and clusters, purely

### 5.1 Inputs

Only evaluator-visible files, read from a path source:

- root `Cargo.toml` (`[workspace]`, `[workspace.dependencies]`, `[patch]`),
- each member's `Cargo.toml`,
- `Cargo.lock`.

No derivation is read, so there is no IFD. Globs in `[workspace].members` are
expanded with `builtins.readDir` on the path source (the current helper refuses
globs; the 24-member workspace will likely need them).

### 5.2 Signature of a member

For member directory `d`, collect its dependency tables:

```
[dependencies], [build-dependencies], [dev-dependencies],
[target.<cfg>.dependencies], [target.<cfg>.build-dependencies],
[target.<cfg>.dev-dependencies]
```

For every entry, resolve `{ workspace = true }` against
`[workspace.dependencies]` with Cargo semantics:

- `version`: member override else workspace version;
- `features`: **union** (workspace features ++ member features — additive);
- `default-features`: member field if present, else workspace field, else
  `true`;
- `optional`, `package` (rename), `path`: member field (workspace may supply
  `path`/`package` too);
- `domain`: normal / build / dev (kept distinct; the host and dev resolvers are
  separate);
- `target`: the `cfg` key, or `"."` for un-gated.

Canonicalise each entry to a sorted string
`domain|name|package|version|features|default-features|optional|target|path` and
hash the sorted multiset:

```nix
signature(m) = builtins.hashString "sha256" (builtins.toJSON {
  deps = sorted canonical entries;
  features = m.features or {};          # conservative: the member's own table
});
```

**Safety lemma.** If `signature(m₁) = signature(m₂)` then building `-p m₁ -p m₂`
resolves every external to the same feature set as building either alone on the
same host with the same lock. _Sketch:_ Cargo feature resolution is the least
fixpoint of the union of feature requirements. Equal direct requirement tables
and equal member feature tables give identical seeds; the lock pins identical
versions; path/internal dependencies are part of the same canonical entries. The
union fixpoint of identical seeds is the seed itself. ∎

Because the lemma is _sufficient but not necessary_, a conservative signature
may report two members as different even when their resolutions coincide. That
only forgoes dedup; it never damages correctness or reuse for a member whose
cluster is a singleton or whose signature truly matches.

We deliberately do **not** key on `Cargo.lock` closure. The lock is the
workspace-union resolution (optional deps activated by _any_ member appear in
it), so two members can share a lock closure but differ on a feature toggle that
adds no package. Closure is a useful _reporting_ metric; the signature is the
_decision_.

### 5.3 Clusters

```
clusters = groups of members by signature(m), sorted deterministically
label(C) = sanitised join of member names (or short signature hash)
```

A cluster with one member is an ordinary exact base. A cluster with several
members is the grouping win.

**Coarser, residual-tolerant grouping (optional knob).** The exact signature is
_safe_ (zero residual). Because features are additive, a weaker but still valid
rule is to group members by their **lock closure** (or by a coarser manifest
key) even when their feature toggles differ: the group base then resolves each
shared external with the union, and a member narrower than the union recompiles
only the toggled crates — i.e. the L residual, but confined to the cluster
instead of the whole workspace. This trades `group size` against `residual`. The
decision rule (§11.3) can pick the granularity by the measured
`Σ clusters / |union|` ratio: exact signatures first, closure grouping as a
middle rung, L's single union base as the bottom. Exact signatures remain the
default because they are the only choice with a _provable_ zero residual.

### 5.4 Cluster source set

From the member manifests, collect `path` dependencies (relative to the member
directory), recurse to a fixpoint, and keep the in-repo ones:

```
sourceDirs(C) = ⋃ { d(m) : m ∈ C }  ∪  transitive path deps (inside the repo)
memberDirs(C) = the member directories (for the root-manifest rewrite)
selection(C)  = "-p m₁ -p m₂ …"
```

`sourceDirs` feeds `mkWorkspaceSourcePath` (a `builtins.path` filter) so the
base depends only on the cluster's manifests plus the lock. `memberDirs` feeds
the root-manifest rewrite at build time.

### 5.5 Planner output

```nix
{
  members = [{ name, dir, signature, internalDeps }];
  clusters = [{ key, label, members, memberDirs, sourceDirs, selection }];
  memberCluster = { "<dir>" = "<cluster key>"; };
}
```

Exposed as `passthru.rustCluster` per package and as a `rustClusters` flake
output for diagnostics.

---

## 6. Exact cargo invocations

Shared, invariant attributes for every base:

```nix
sharedVendor   = craneLib.vendorCargoDeps { cargoLockContents = lock; };  # ONE dir
lockContents   = builtins.readFile (src + "/Cargo.lock");
baseCommon = {
  version = "0.1.0";
  cargoVendorDir = sharedVendor;
  cargoLockContents = lockContents;
  # NOTE: no --locked. The root member list is rewritten to the cluster, which
  # can make cargo want to touch the lock; --offline + vendor handles it and
  # never changes a used package's version (validation gate V4).
};
```

### 6.1 B0 — independent cluster base (assigned baseline)

```nix
base(C) = craneLib.buildDepsOnly (baseCommon // {
  pname = "abird-rust-${C.label}";                     # → …-deps
  dummySrc = craneLib.mkDummySrc {
    src = mkWorkspaceSourcePath pkgs { selectedDirs = C.sourceDirs; };
  };
  prePatch = cargoWorkspaceMembersPrePatch { members = C.memberDirs; };
  cargoExtraArgs = "--offline ${C.selection}";
  # doCheck = true (default): check --all-targets, build, test --no-run
});
```

`buildDepsOnly`'s phases (crane source, verified) are exactly:

```
buildPhase:  cargoWithProfile check --offline <sel> --all-targets
             cargoWithProfile build --offline <sel>
checkPhase:  cargoWithProfile test  --offline <sel> --no-run
install:     install cargo artifacts
```

so normal, build/host/proc-macro, dev/test, and bench/example units are all
primed, and `doInstallCargoArtifacts = true`.

### 6.2 B1 — chained cluster base (recommended at scale)

```nix
base(C) = craneLib.mkCargoDerivation (baseCommon // {
  pname = "abird-rust-${C.label}-deps";
  src   = craneLib.mkDummySrc {
    src = mkWorkspaceSourcePath pkgs { selectedDirs = C.sourceDirs; };
  };
  prePatch = cargoWorkspaceMembersPrePatch { members = C.memberDirs; };
  cargoArtifacts = parent(C);          # previous cluster base, or spine base
  doCheck = true;
  doInstallCargoArtifacts = true;
  buildPhaseCargoCommand = ''
    cargoWithProfile check --offline ${C.selection} --all-targets
    cargoWithProfile build --offline ${C.selection}
  '';
  checkPhaseCargoCommand = ''
    cargoWithProfile test --offline ${C.selection} --no-run
  '';
});
```

`parent(C)` is either the previous cluster in a deterministic chain (B1-chain)
or a shared **spine** base built from a small anchor selection (B1-spine,
§11.3). Either way `base(C)` still _resolves its own exact selection_;
inheritance only lets Cargo reuse matching units from the parent.

**Why not `buildDepsOnly` for B1:** `buildDepsOnly` hard-codes
`cargoArtifacts = null` (crane `lib/buildDepsOnly.nix`, verified). B1 reproduces
its three phases verbatim above. B0 is the faithful "`buildDepsOnly` per
signature" baseline; B1 is the cost-control variant.

### 6.3 Member layer (zero external recompiles)

```nix
clusterBase = base(cluster(m));
dependencyMemberLayers = …;                # as today, from internalDeps passthru

memberLayer(m) = craneLib.cargoBuild (craneCommonAttrs // {
  cargoArtifacts =
    if dependencyMemberLayers == [] then clusterBase
    else mkCargoArtifactsJoin pkgs { name = pname;
                                     deps = [clusterBase] ++ dependencyMemberLayers; };
  cargoExtraArgs = "--offline -p ${pname}";
  doInstallCargoArtifacts = true;
});
```

Because `signature(m) = signature(C)`, `base(C)`'s resolution for every external
equals `-p m`'s resolution, so `cargo build -p m` emits no `Compiling` line for
any external in the cluster's closure. Internal dependencies are still joined in
(their real rlibs replace the dummy ones).

### 6.4 Packages and checks

```nix
build(m)   = craneLib.buildPackage (craneCommonAttrs // { cargoArtifacts = memberLayer(m); … });
checks.test  = craneLib.cargoTest  (mkCraneCheckAttrs { … cargoArtifacts = memberLayer(m); });
checks.lint  = craneLib.cargoClippy(…);
checks.fmt   = craneLib.cargoFmt (…);     # no artifacts; real workspace, no synthesis
```

Unchanged from L except the artifact source.

---

## 7. Feature semantics

### 7.1 Residual elimination

For every member `m`, the base it inherits was built with a selection whose
signature equals `signature(m)`. By the lemma (§5.2) the resolved feature sets
for all externals are identical, so fingerprints match and no external is
recompiled. This holds in all three Cargo dependency domains (normal,
build/host/proc-macro, dev/test) because the signature includes `domain` and
`target`, and the base phases exercise all three.

### 7.2 Default-features polarity

No manifest is generated for a base. The base's selection is real member
manifests, so a member with `default-features = false` is resolved with defaults
off, exactly as its own build would. Groups only contain members whose
`default-features` fields (and all other fields) are equal, so a cluster base
can never force defaults onto a member that disabled them. This is the Plan A
BLOCKER, and it is structurally impossible here.

### 7.3 Why this is not just "L with more bases"

In L, the base is a _union_ that member layers can never match. In Plan B, the
base at index k is the union of a set of members that is _closed under identical
signatures_, and every member inherits the base whose union is its own
resolution. The invariant is "base selection ≡ member resolution", not "base
selection ⊇ member resolution".

---

## 8. Dev-dependencies and tests

- `buildDepsOnly` defaults `doCheck = true`, so each cluster base runs
  `cargo test --offline <sel> --no-run`, priming dev-deps and test targets for
  every member of the cluster. Member `checks.test` inherits `memberLayer(m)`
  and hits the cache.
- `signature(m)` includes `[dev-dependencies]` and
  `[target.<cfg>.dev-dependencies]`, so dev-feature unification is part of the
  grouping decision.
- Resolver `3` keeps dev-deps out of the normal feature domain; the base's
  normal units come from the `cargo build` phase that runs before the test
  phase, so the member's `cargo build -p m` matches the normal units.
- If dev-dep churn is later shown to be noisy, a dedicated test chain is an
  isolated extension of the same mechanism (a second set of bases selected only
  for test). Not needed initially.
- P2-e (deploy-time test recompile in L) is fixed for free: the base already
  primed tests; `buildAttrs.doCheck = false` members remain untouched.

---

## 9. Internal dependencies

The repo has one edge, `manager -> agent`, but the design must scale.

- The planner includes transitive `path` deps in `sourceDirs(C)` so a cluster
  base can resolve them; they are dummified inside the base.
- The real internal dep code arrives through the existing `internalDeps` layers.
  `memberLayer(m)` joins `clusterBase(m)` with the dependency layers
  (`mkCargoArtifactsJoin`), because `clusterBase(m)` only contains the dummy
  internal crate.
- `memberLayer(dep)` may have a different cluster base than `m`; if `m` requests
  different features on `dep` than `dep` resolves itself, Cargo recompiles `dep`
  inside `m`'s layer. That is correct and is the one residual Plan B cannot
  remove without forcing `dep`'s feature union (Plan A's job). It is bounded to
  in-repo crates (small) and disappears when signatures align or the dependent
  adds no features (the current case).
- Joining `clusterBase(m)` with `depLayer` can carry two variants of the same
  external crate (built under different features). That is expected; Cargo
  selects the matching fingerprint. The join is a full archive
  (`mkCargoArtifactsJoin`), so keep fan-in rare and shallow.
- Internal-dependency pairs can never share a cluster: `signature(manager)`
  contains the `agent` entry that `signature(agent)` lacks, so clusters are
  closed under the internal edge by construction.

---

## 10. Platform gating and native inputs

- **Signature includes every `target.<cfg>.*` table**, so a member's Darwin-only
  deps cannot unify with another member's Linux-only deps.
- **Clusters are computed per `hostPlatform`.** A member whose `meta.platforms`
  excludes the host is dropped from cluster membership for that host. Since the
  planner is manifest-only, the host filter is supplied by the caller (the flake
  composition layer knows `meta`); the default is "all members".
- **Base-level native inputs must be uniform per cluster.** Cargo builds `*-sys`
  crates using `nativeBuildInputs`/`buildInputs` from the derivation, which is
  _not_ visible in the manifest. Options, in order:
  1. hoist the workspace-wide set to a root option (`rustWorkspaceNativeInputs`)
     added to every base;
  2. treat a per-member native-input _profile_ as part of the cluster key, so
     members needing different inputs never share a base;
  3. give the cluster base the union of its members' inputs. Start with (1)+(2);
     (3) risks hash-consing surprises. This closes review finding P1-A for the
     base, which L left unfiltered.
- `nativeCheckInputs` (e.g. `rsync` for agent tests) stay on `memberLayer`/
  `checks` as today and never enter the base.

---

## 11. Cost, duplication, and the scaling decision

### 11.1 Measured shape of this repo (5 members)

From `Cargo.lock` closures (package granularity, internal members excluded):

| member                 | external closure |
| ---------------------- | ---------------: |
| hello-rust             |                0 |
| abird-host-agent       |               65 |
| nats-wrecking-ball     |              216 |
| abird-host-manager     |              233 |
| nats-http-bridge       |              239 |
| **union**              |          **367** |
| **Σ (B0, no sharing)** |          **753** |

Distinct signatures at 5 members: **5** (all lock closures differ, and the
direct signatures differ too), so the assigned hybrid degenerates to five
singleton bases here. External-external overlap: 42 crates appear in all four
rich members, 83 in three, 94 in two, 148 in exactly one.

Consequences:

- **B0 at 5 members:** ≈ 753 external compilations vs L's ≈ 367 + residual. That
  is ~2.05× the union. Raw CPU/store is worse; wall-clock can still be
  competitive because Nix builds the five bases in parallel and the longest
  closure (239) is shorter than the union (367). B0 is _not_ a compile-count win
  at 5 — it is a residual + locality win.
- **B1 at 5 members:** chain the clusters in increasing-closure order (agent →
  wrecking → manager → bridge, with hello-rust trivial). Each base reuses the
  parent's matching units. Bounds: **367 ≤ compiles ≤ 753**; realistic ≈ union +
  feature-divergence recompiles, i.e. L-class counts, with **zero member-layer
  residual**. This is the recommended 5-member shape.
- **Spine variant:** a spine built from the two largest anchors (manager,
  bridge) covers 365 of 367 externals; the remaining clusters recompile only
  their private deltas (~23 for wrecking, 0 for agent). This approaches the
  union while keeping spoke sources local. Its cost is churn: a manifest edit to
  an anchor rebuilds the spine and all spokes.

### 11.2 Extrapolation to 24 members

Let `K` = number of clusters, `C_k` = external closure of cluster `k`, `U` =
|union|.

- **B0 independent:** `Σ_k |C_k|`. With rich members and low signature
  repetition, this grows ≈ linearly in the member count while `U` saturates.
  Applying this repo's pairwise Jaccard (~0.3) to 24 members gives roughly 8–10×
  `U`. Unacceptable as a default.
- **Grouping by identical signature:** `Σ_k |C_k|` with `K < M`. It helps only
  where manifests are genuinely duplicated (common in fleets of similar
  binaries). This repo's five members are all distinct, so grouping alone is not
  enough at scale.
- **B1 chain / spine:** compiles ≈ `U` + divergences, i.e. L-class. This is what
  makes Plan B viable at 24 while keeping zero member residual and real
  (`default-features`-exact) selections.
- **Parallelism:** Nix builds clusters concurrently; B0's wall-clock is bounded
  by the largest cluster, but its store/CPU cost is the sum. On a remote build
  farm, total derivations and store growth matter more than wall-clock.

### 11.3 Decision rule (deterministic, evaluated from the plan)

```
if no member is clusterable:                       use L's shared base (fallback)
else if Σ_k |C_k| ≤ threshold · |U| (e.g. 1.5×):   use B0 (independent)
else if churn locality outweighs dedup:            use B1-spine over B0
else:                                              use B1-chain
```

- `threshold` is a knob (flake-level, default ~1.5).
- **B1-spine** (spine = deterministic anchor set, spokes inherit only the spine)
  keeps spoke manifest churn local; choose anchors by (coverage × stability).
- **B1-chain** maximizes dedup; a manifest change in cluster `i` rebuilds the
  suffix `i..K`, so order clusters by decreasing stability (hello-rust first).
- Per-member singleton bases are the always-valid degenerate case, and the
  zero-risk endpoint used during migration.

### 11.4 Churn-locality summary

| change                             | L                    | B0                  | B1-spine                                 |
| ---------------------------------- | -------------------- | ------------------- | ---------------------------------------- |
| `.rs` content in `m`               | member + dependents  | member + dependents | member + dependents                      |
| `Cargo.toml` of `m`                | base (all externals) | cluster(`m`) only   | spoke(`m`) only; spine iff `m` is anchor |
| `Cargo.lock` / root workspace deps | base (all externals) | all clusters        | spine + all spokes                       |
| new member                         | base (all externals) | new cluster only    | new spoke only                           |

Root-level changes (`Cargo.lock`, `[workspace.dependencies]`, `[patch]`)
legitimately invalidate everything; `mkWorkspaceSourcePath` always keeps those
files.

---

## 12. Diagnostics, degradation, and failure modes

- `passthru.rustCluster = { key; label; members; selection; base; }` on every
  package; a `rustClusters` flake output printing the partition, the decision
  (`B0`/`B1`/`legacy`), and the chosen threshold.
- `lib.warn` on every degrade: glob member the planner cannot expand, manifest
  parse failure, member outside the repo's path-dep graph, cluster count above
  threshold, `craneLib == null`, non-workspace `projectDir`.
- Planner uses `builtins.tryEval` around each manifest parse and drops the
  member to the legacy per-package path on failure (warning, never throw).
- `hello-rust` (empty closure) and any member with no externals use the legacy
  path or a trivial base; never an empty cluster derivation.
- Legacy / `useWorkspaceDeps = false` rollback stays exactly as in L, so a
  single package can always opt out.
- No synthetic workspace means `cargo metadata` (buildPackage install),
  `cargo
  fmt`, and `cargo clippy` always see the real, valid workspace. Plan
  A's P1 `fmt`/`metadata` problem does not exist here.
- Lock drift / `--offline` re-resolution is validated by V4 (§14), not assumed.

---

## 13. Migration (staged, behind the L seams)

1. **B0-plan (diagnostic).** Add `lib/flake/rust-workspace.nix`; expose
   `rustClusters`; no build change. Validate the partition against the lock and
   compare predicted external counts with L.
2. **B1-singletons.** Switch each member to a singleton cluster base (`-p m` in
   both base and layer). Verify zero external `Compiling` lines in member layers
   and that member layers still reuse. This proves residual elimination with the
   smallest possible grouping.
3. **B2-grouping.** Enable signature grouping. Measure K, Σ closures, and the
   decision-rule ratio; confirm identical-signature clusters produce no
   residual.
4. **B3-inheritance.** If the ratio exceeds the threshold, enable B1-spine (or
   B1-chain) with `mkCargoDerivation`.
5. **Fallback and cleanup.** Keep L's `mkSharedRustDepsBase` as the fallback
   path; delete the synthetic machinery from Plan A's branch if it exists.

Seams held stable: `src`/`dummySrc` injection, `cargoArtifacts` injection, a
cluster label, and untouched `checks`/`pkgOps`/`devShell`/`passthru` wiring. The
public `mkRustDerivation` contract is unchanged; the only new optional argument
is a `clusterMode`/threshold knob.

---

## 14. Validation and spike gates

Run all gates with IFD disabled:
`nix eval --option allow-import-from-derivation false .#<pkg>.drvPath`.

- **V1 — No IFD.** All packages evaluate; the planner never reads a derivation.
  Grep the new module for `readFile`/`readDir`/`pathExists` and confirm each is
  guarded by `builtins.isPath`.
- **V2 — Zero residual (the headline).** For each member, build `memberLayer`
  and assert the log contains **no** `Compiling <external>`. Cross-check
  `nix derivation show -r` shows the base + member edges.
- **V3 — `.rs` locality.** Append to a member `.rs`; assert every cluster base
  drv path is byte-identical and only the edited member's layer/package change.
- **V4 — Lock fidelity.** Inside a cluster base, diff the resolved lock /
  `cargo metadata --offline` against the committed `Cargo.lock`; assert no
  version of a used package changed (guards against fact 3's silent downgrade).
  This is the second load-bearing unknown.
- **V5 — Polarity.** For a member using `default-features = false` (e.g.
  `reqwest`, `ssh-key`), assert the base and member resolve the same features
  (`cargo tree -e features --offline`) and that no default-only dep appears.
- **V6 — Manifest churn locality.** Edit one member's `Cargo.toml`; assert only
  its cluster base (B0) or spoke (B1-spine) drv changes.
- **V7 — Fingerprint alignment.** Confirm cross-source reuse: the
  cluster-filtered dummy source and the member-filtered real source both unpack
  to `/build/cargo-workspace-source`, and one shared vendor dir is used by all
  bases and layers.
- **V8 — Closure isolation.** `nix path-info -r` on deployed packages shows no
  artifact archive (unchanged from L).
- **V9 — Eval tests.** Partition is deterministic; every member in exactly one
  cluster; equal signature ⇔ same cluster; degrade-without-throw; join
  evaluates.
- **V10 — Correctness.** `nix flake check`, plus `nix build` for every package
  and the isolated child flake.

---

## 15. Honest comparison

### 15.1 vs Plan A (F-union)

| dimension                   | Plan A                                                                      | Plan B (F-cluster)                                             |
| --------------------------- | --------------------------------------------------------------------------- | -------------------------------------------------------------- |
| `default-features` polarity | **BLOCKER**: one aggregate cannot represent opposing flags; silent widening | exact — real manifests only                                    |
| correctness source          | generated union must faithfully mirror Cargo                                | Cargo itself; grouping is advisory                             |
| `cargo fmt` / `metadata`    | synthetic workspace + lock-absent aggregate                                 | real workspace, unmodified                                     |
| lock handling               | re-resolution / silent downgrade risk                                       | same lock + shared vendor, validated (V4)                      |
| dep-manifest churn          | global base rebuilds all externals                                          | per-cluster (B0) or spoke (B1-spine); only root/lock is global |
| cold-compile dedup          | **best**: one union base                                                    | B0 duplicates; B1 ≈ union + divergences                        |
| residual                    | 0 (forced)                                                                  | 0 (identical base selection)                                   |
| derivations                 | 1 base + 1 aggregate + N layers                                             | K bases (+spine) + N layers                                    |
| maintenance                 | planner must reimplement resolution                                         | planner computes manifest signatures only                      |

**Plan B beats Plan A** whenever any shared dependency uses
`default-features = false` (this repo does), whenever `cargo fmt`/`metadata`
must run unmodified, whenever manifest churn locality matters, and whenever the
workspace clusters by signature. **Plan A beats Plan B** on raw cold-compile
dedup and on base-graph simplicity; if a repo has no default-features polarity
conflicts and does not care about churn, Plan A is smaller.

### 15.2 vs landed Design L

| dimension                      | L                | B0                | B1 (spine/chain)   |
| ------------------------------ | ---------------- | ----------------- | ------------------ |
| residual recompiles            | yes (syn, clap)  | **no**            | **no**             |
| `.rs` locality                 | yes              | yes               | yes                |
| dep-manifest churn             | global           | per-cluster       | spoke/chord        |
| external compile count @5      | ≈ 367 + residual | ≈ 753             | ≈ 367–450          |
| external compile count @24     | 1 base, best     | risky (≈8–10×)    | ≈ 1× + divergences |
| complexity                     | low              | medium            | medium-high        |
| risk of correctness regression | none             | none (cache only) | none (cache only)  |

**Plan B is a strict refinement of L**: it keeps L's fallback, removes the
residual by construction, and adds a tunable dedup/churn trade-off. B0 alone is
only worth it when grouping is effective or when compile _count_ is cheaper than
cache invalidation; B1 is required to match L's compile count at 24.

### 15.3 When Plan B is the right choice

- The workspace has **opposing `default-features` polarity** (or any manifest
  property Plan A cannot faithfully aggregate).
- **Churn locality** and remote-cache granularity matter more than a single fat
  base.
- The member set **clusters by signature** (fleets of similar binaries), or the
  team accepts B1 inheritance.
- You want a **failure-tolerant** design: a bad grouping degrades performance,
  never correctness.

Choose Plan A instead when raw cold-compile dedup dominates and churn/polarity
are non-issues; keep L when the residual is acceptable and simplicity wins.

---

## 16. Open questions

- `extraDummyScript` vs `prePatch` for the root-member rewrite: `prePatch` on
  `buildDepsOnly` is simpler and keeps the dummy derivation `.rs`-free; confirm
  it runs before every cargo phase (it does in `mkCargoDerivation`).
- Spine anchor selection (coverage × stability) and whether to compute it
  automatically or declare it at the flake root.
- Whether `nativeInputsProfile` belongs in the signature or is hoisted to a root
  option.
- Per-host cluster computation needs `meta.platforms`, which the manifest-only
  planner cannot see; thread it from the composition layer.
- Whether to route `mkTrunkProject`/`mkCraneRustPackage` through the same
  planner once the member path is stable.
- Threshold default and whether the decision rule should be exposed or fixed.

## References

- `.agents/docs/plans/design-f-build-graph-2026-09.md` — Design F draft.
- `.agents/docs/plans/rust-workspace-build-graph-2026-09.md` — L/F handoff.
- `.agents/docs/notes/tooling/rust-build-graph-review-2026-09.md` — P1/P2
  findings (P1-A native-input seam, P1-B diagnostics, P2-e tests).
- `lib/flake/pkg-helper.nix` — `mkSharedRustDepsBase` (179-195),
  `mkCargoArtifactsJoin` (198-219), `memberLayer` (2400-2411).
- Crane source `lib/buildDepsOnly.nix` (rev `73b9805`) —
  `cargoArtifacts =
  null`, `doCheck = true`, check/build/test phases.
