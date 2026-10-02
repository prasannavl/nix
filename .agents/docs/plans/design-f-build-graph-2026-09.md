# Design F — REWEAVE: force the feature union by rewriting member manifests

> **Superseded / rejected** for the dual-mode goals (G10/G11): REWEAVE's union
> manifest rewrite makes a package's semantics depend on its monorepo peers, so
> standalone and merged builds can differ. Kept as prior art. The final design
> is `.agents/docs/plans/dual-mode-rust-build-graph-2026-09.md` (Design M).

Status: **final, implementation-ready plan** (adjudicates Plans A/B/C and the
fresh review). Supersedes `.agents/docs/plans/design-f-build-graph-2026-09.md`
and the Design F sketch in
`.agents/docs/plans/rust-workspace-build-graph-2026-09.md`. Builds directly on
landed Design L: `mkSharedRustDepsBase` (`lib/flake/pkg-helper.nix:179-195`),
`memberLayer` (`lib/flake/pkg-helper.nix:2400-2411`), `mkWorkspaceSourcePath`
(`67`), `cargoWorkspacePrePatch` (`235`), `mkCargoArtifactsJoin` (`198-219`),
`rustWorkspaceMembers` (`142`), `mkRustWorkspaceSource` (`167`).

---

## 0. Decision (one paragraph)

Adopt **Plan C (REWEAVE), corrected and hardened** as the final architecture:
keep Design L's single-base shape, and force each member's `-p m` resolution to
equal the base's resolution by **rewriting the member's own external dependency
declarations in `prePatch` to the shard's computed external union**. The base is
built from the **same declarations** (real shard members with the root member
list rewritten) and therefore resolves the identical closure. No synthetic
crate, no synthetic lock package, no IFD. A `polarity-vector` shard key makes
`default-features = false` exact; members whose `[features]` table activates an
external are conservatively placed in their own shard (REWEAVE-S), which makes
the union exact without a resolver. A mandatory build-time `checks.union-fresh`
gate empirically proves zero external recompiles per member and fails CI if the
projection is ever under-approximated. Plan A's synthetic aggregate is rejected
as the spine (polarity/aggregate lock/metadata friction) but its build-time
feature-equality gate and diagnostics are adopted. Plan B's per-signature
clustering is rejected as the headline shape (B0 is a measured ~2.05× compile
regression, failing the primary goal) but its "correctness must not depend on
the grouping heuristic" principle is retained through the gate and the singleton
fallback.

### 0.1 One-line goal restatement

Every external crate compiles **once per (host, external-policy shard)** in a
shard base; every member layer reuses it. `.rs` content edits stay local to the
edited member and its dependents. Manifest edits stay local to the shard (one
shard in the uniform-polarity case, which is the honest cost of maximal dedup).
No IFD; `pkgHelper.mkRustDerivation { projectDir; … }` unchanged.

---

## 1. Why the three plans exist, and the common mechanism

All three try to make a member's `-p m` selection resolve the same features as
the base it inherits (feature unification is selection-based, not
membership-based; `default-features=false` can never subtract defaults another
edge enabled). There are exactly three levers:

| lever                                         | plan  | shape                                       |
| --------------------------------------------- | ----- | ------------------------------------------- |
| add the union to the selection                | **A** | `-p m -p crane-union` (synthetic aggregate) |
| change the base to match the member           | **B** | one real `-p S` base per signature cluster  |
| change the member's declarations to the union | **C** | rewrite `m`'s external tables to `U(S)`     |

REWEAVE is lever C. The reason to prefer it:

- It is a strict refinement of landed L (same single base, same seams, same
  fallback), so it is the smallest conceptual delta and the most composable.
- It reaches the union (one compile per external) **without** a synthetic crate,
  so `cargo metadata` / `cargo fmt` / `cargo clippy` always see real,
  lock-consistent manifests, and there is no synthetic lock entry to re-resolve
  or downgrade.
- Lever B is exact by construction but cannot share a base across differing
  signatures; at this repo it degenerates to five singleton bases and ~753
  external compiles (measured) instead of 367. Lever A forces the union but pays
  for it with a lock-absent aggregate and a polarity blocker.

The correctness argument for lever C is short and does not require a resolver:

> For external declarations, `U(S)` is a **superset** of every member's own
> declarations, and transitive feature requests come from the same vendored
> package sources in the base and the member. If every direct external
> declaration of every shard member is present in every member's manifest, the
> base and the member have the **same root requirement table** and therefore the
> same feature fixpoint. Differences are only additive (features) or are
> excluded from sharing (`default-features` polarity, external `[features]`
> activation).

The residual risk is that the projection under-approximates somewhere a human
did not anticipate. That risk is bounded and converted into a hard failure by
the freshness gate (§11), not left silent.

---

## 2. Adjudication of the three candidates

### 2.1 Plan A (F-union, synthetic aggregate)

**Verdict: reject as the spine; adopt its gate and diagnostics.**

| finding                                                                               | decision   | reasoning                                                                                                                                                                                |
| ------------------------------------------------------------------------------------- | ---------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| BLOCKER: one aggregate cannot represent `default-features` polarity                   | **accept** | Real. The repo already has `reqwest`/`ssh-key` `default-features = false`; one aggregate silently widens. REWEAVE avoids it by sharding on the polarity vector and rewriting per member. |
| BLOCKER: `exactly-once` only as sound as a pure-eval planner with no failure detector | **accept** | Real. Even per-member aggregates leave the union unverified. REWEAVE adopts Plan A's own remedy as a mandatory `checks.union-fresh`.                                                     |
| P1: global base ⇒ dep-manifest change rebuilds all externals                          | **accept** | REWEAVE has the same property in the one-shard case; sharding and the deferred canonical base localize it. Not hidden.                                                                   |
| P1: lock re-resolution / silent downgrade                                             | **accept** | REWEAVE keeps `--locked` for the base and pins injected member deps to `=locked`, with V4.                                                                                               |
| P1: `cargo fmt` / `cargo metadata` on a lock-absent aggregate                         | **accept** | No synthetic crate in REWEAVE, so this class disappears.                                                                                                                                 |
| P1: `[build-dependencies]` in the aggregate are inert without `build.rs`              | **accept** | No aggregate. REWEAVE's build-deps are real member tables and are exercised by the base's `cargo check/build`.                                                                           |
| P2: planner over-scoped                                                               | **accept** | REWEAVE's planner is a declaration merger + activation detector, not a demand lattice/closure engine.                                                                                    |
| P2: global aggregate kills per-member manifest locality                               | **accept** | REWEAVE shards; honest about the one-shard case.                                                                                                                                         |
| P2: target tables / edition                                                           | **accept** | Target tables are merged per `cfg`; `[package]`/`[lib]`/`[[bin]]`/edition are preserved verbatim.                                                                                        |
| P2: base and aggregate must derive from the same filtered member set                  | **accept** | REWEAVE derives base, member, and rewrite from the same plan object.                                                                                                                     |
| P2: `workspace_members` pollution / collision                                         | **accept** | No synthetic member exists.                                                                                                                                                              |
| P2: glob-degrade wording                                                              | **accept** | REWEAVE expands simple globs; only non-expandable globs degrade, with a warning.                                                                                                         |
| P2: folding `doCheck` into the member layer changes the deployed build                | **accept** | REWEAVE does not fold; the shard base primes tests and `buildPackage` keeps its existing `doCheck` semantics.                                                                            |

### 2.2 Plan B (F-cluster, per-signature bases)

**Verdict: reject as the headline; retain its safety principle and native-input
lesson.**

| finding                                                                                | decision   | reasoning                                                                                                                |
| -------------------------------------------------------------------------------------- | ---------- | ------------------------------------------------------------------------------------------------------------------------ |
| BLOCKER: B0 is a ~2.05× compile regression at the real scale; own 1.5× rule rejects it | **accept** | Measured exact: `{0,65,216,233,239}`, union 367, sum 753. Failing the primary goal is disqualifying.                     |
| BLOCKER: drops `--locked` on a false premise                                           | **accept** | `--locked --offline -p a` on a rewritten member list preserves the lock. REWEAVE keeps `--locked` where no edges change. |
| P1: signature proves feature equality, not reuse (fingerprint inputs missing)          | **accept** | Real. REWEAVE does not claim a proof: it adds the freshness gate and includes native-input profile in the shard key.     |
| P1: signature is a lossy hand-rolled projection                                        | **accept** | REWEAVE does not rely on a signature for correctness; it uses polarity + activation detection + gate.                    |
| P2: churn table wrong for root/lock/workspace.deps edits                               | **accept** | Documented honestly in §12.                                                                                              |
| P2: B1 reimplements `buildDepsOnly`                                                    | **accept** | REWEAVE uses `buildDepsOnly` unchanged for the base.                                                                     |
| P2: join used for a single internal dep                                                | **accept** | REWEAVE keeps L's single-dep special case.                                                                               |
| P2: dev-deps vs native inputs                                                          | **accept** | Native/check input profile is in the shard key and on the base.                                                          |
| NOTE: B1 omits `CRANE_BUILD_DEPS_ONLY`                                                 | **accept** | The shard base is `buildDepsOnly`, which sets it.                                                                        |

### 2.3 Plan C (REWEAVE)

**Verdict: accept with corrections. All blockers/P1s are fixed or converted into
a fail-closed gate; none is architectural.**

| finding                                                                                              | decision           | reasoning / fix                                                                                                                                                                                                                                                                                                                                                  |
| ---------------------------------------------------------------------------------------------------- | ------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| BLOCKER B1: union includes shard-mates' path deps ⇒ members cannot find internal dirs                | **accept**         | Fix: the union is **externals only**. Each member keeps its own internal path-dep entries verbatim. Shards are closed under internal path-dep edges.                                                                                                                                                                                                             |
| BLOCKER B2: filtered shard base leaves root `[workspace].members` unfiltered ⇒ `--workspace` fails   | **accept**         | Fix: apply the existing `cargoWorkspacePrePatch` member-list rewrite to the shard base, not only to member builds.                                                                                                                                                                                                                                               |
| P1: exactness false for member `[features]` external activations                                     | **accept**         | Fix: members whose `[features]` references an external (`dep:<ext>` or `<ext>/<feat>`) are placed in their own shard (REWEAVE-S) unless/until an activated-feature closure is implemented. In a shared shard no external activation exists, so the root tables are identical. Gate catches any residual.                                                         |
| P1: `optional = AND` + preserved `[features]` gives a hard parse error                               | **accept**         | Fix: because external activations are sharded alone, no `dep:<ext>` survives in a shared shard; `AND` is then correct (a non-optional member dependency stays non-optional). Add an eval assertion that no shared-shard member has an external `[features]` reference.                                                                                           |
| P1: churn-locality claim false when polarity is uniform                                              | **accept**         | Honest: with uniform polarity (this repo) the default is one shard and manifest churn is global, exactly like L. Sharding trades dedup for locality; expose it as a knob.                                                                                                                                                                                        |
| P2: declaration-level polarity sharding misses transitive activation                                 | **accept**         | `Cargo.lock` carries no feature data, so no pure-eval design can see it (this also affects A and B). Documented as additive widening (same policy as the landed W10 `[workspace.dependencies]` normalization); the freshness gate catches the resulting _recompile_, not the widening. A polarity audit for `default-features=false` crates is a gate (§14, V5). |
| P2: keying by requirement string, not resolved version                                               | **accept**         | Fix: resolve families from `Cargo.lock`; if a shard contains two version families of one package, split by family (conservative). Inject non-member families pinned `=locked`.                                                                                                                                                                                   |
| P2: shard closure under internal path deps unenforced                                                | **accept**         | Fix: compute connected components over internal path-dep edges and build shards from whole components.                                                                                                                                                                                                                                                           |
| P2: `extraDummyScript` clobbers crane's dummy build-script stub                                      | **accept**         | Fix: do **not** use `extraDummyScript` in v1. The base uses real member manifests plus the root-members rewrite. The canonical base is deferred (§13, F4) and, if built, must splice only dependency tables via `cleanCargoTomlFilter`/`recursiveUpdate`, never replace the manifest.                                                                            |
| NOTE: partial resolver reimplementation                                                              | **partial accept** | The planner is a declaration merger plus an activation _detector_, not a feature resolver. It never computes closures, semver, or feature fixpoints. The gate is the correctness backstop.                                                                                                                                                                       |
| Good: no IFD, API unchanged, `.rs` locality, no new lock packages, shard continuum, failure detector | **accept**         | These are the reasons Plan C is the spine.                                                                                                                                                                                                                                                                                                                       |

### 2.4 What each plan got right that is folded in

- **A:** build-time feature-equality / freshness gate; `lib.warn`-not-throw
  degradation; `passthru`/`rustPlan` observability; explicit base seam for
  members and native inputs.
- **B:** correctness must not depend on the grouping heuristic; native-input
  profile as a sharing key; conservative projection; singleton fallback.
- **C:** manifest rewrite as the forcing mechanism; shard-key continuum; no
  synthetic lock package; the zero-external-`Compiling` detector.

---

## 3. Architecture and module boundaries

```text
                     pure eval (no IFD)                       build time
root Cargo.toml + member Cargo.toml + Cargo.lock         ┌────────────────────────┐
+ host + native-input profiles                          │ shardBase(S)           │
      │                                                 │  buildDepsOnly:        │
      ▼                                                 │   dummySrc(S dirs)     │
lib/flake/rust-workspace.nix  (planner, pure)           │   root-members rewrite │
├─ members, globs, workspace inheritance                │   --locked --offline   │
├─ external decls per domain/target                     │   --workspace          │
├─ polarity vector, activation flags                    │   native/base inputs   │
├─ internal path-dep components                         └───────────┬────────────┘
├─ shards S, union U(S), canonicalManifest(m,S)                     │ cargoArtifacts
└─ plan { members, shards, chain, diagnostics }         ┌───────────▼────────────┐
      │                                                 │ memberLayer(m)         │
      ▼                                                 │  src = perMemberSrc(m) │
lib/flake/pkg-helper.nix (emitter)                      │  prePatch installs     │
├─ shard source + root-members prePatch                 │   canonicalManifest    │
├─ writeTOML(canonicalManifest) (build-time only)       │  --offline -p m        │
├─ shardBase, memberLayer, buildPackage, checks         │  doInstallCargoArtifacts│
└─ passthru.rustPlan / flake.rustPlan                   └────────────────────────┘
```

- **`lib/flake/rust-workspace.nix` (new, pure).** Inputs: repo root path,
  `hostPlatform` (string), a `nativeInputsProfileOf` function (or a per-member
  attrset), and a `shardMode` knob. No `pkgs`, no crane, no derivations. Reads
  only `builtins.readFile`/`fromTOML`/`readDir`/`pathExists` on
  evaluator-visible paths. Outputs a plain attrset (the plan).
- **`lib/flake/pkg-helper.nix` (modified).** Consumes the plan. The public
  `mkRustDerivation` argument set grows only optional fields (`rustPlan ? null`,
  `rustWorkspaceShardMode ? null`, `nativeInputsProfile ? null`); defaults
  preserve the current API and the L behavior.
- **No crane types cross the boundary.** The planner returns data; the emitter
  turns it into derivations. This is the "pure planner / mechanical emitter"
  seam the repo already promised.

---

## 4. Planner (pure eval, minimal)

### 4.1 Inputs and preconditions

- Root `Cargo.toml`: `[workspace] members` (simple globs expanded with
  `builtins.readDir` + `builtins.match`), `[workspace.dependencies]`,
  `[workspace.package]`, `[patch]`.
- Each member `Cargo.toml`.
- `Cargo.lock` (for version-family resolution and diagnostics only).
- Host string and the native-input profile per member (supplied by the
  composition layer; the manifest-only planner cannot see them).

If any manifest fails to parse, or a glob cannot be expanded, or
`[patch]`/`[replace]` differs across candidate shard-mates, return the plan with
those members marked `degrade = "l"` (the emitter falls back to Design L for
them) and a `warnings` list. Never throw.

### 4.2 Declaration model

For member `m`, collect entries from all of:

```text
[dependencies]                         [build-dependencies]            [dev-dependencies]
[target.<cfg>.dependencies]            [target.<cfg>.build-dependencies]
[target.<cfg>.dev-dependencies]
```

Accept both hyphenated and underscore table aliases. Each entry is keyed by
`(domain, target, key)` where `domain ∈ {normal, build, dev}`, `target = "."` or
the literal `cfg` string, and `key` is the dependency key.

`resolveDep` against `[workspace.dependencies]` (Cargo semantics, verified):

```nix
resolveDep = wsDeps: key: decl:
  if decl.workspace or false then
    let w = wsDeps.${key} or {}; in
    decl // w // {
      version         = decl.version         or w.version         or null;
      package         = decl.package         or w.package         or key;
      features        = unique ((w.features or []) ++ (decl.features or []));
      default-features =
        if decl ? default-features then decl.default-features
        else if w ? default-features then w.default-features
        else true;
      optional        = decl.optional        or w.optional        or false;
      path            = decl.path            or w.path            or null;
    }
  else decl // {
    features        = unique (decl.features or []);
    default-features = decl.default-features or true;
    optional        = decl.optional or false;
    path            = decl.path or null;
  };
```

`external(m)` = entries with `path == null`. `internal(m)` = entries with
`path != null` (kept verbatim, never merged into `U(S)`).

### 4.3 Polarity and activation flags

```nix
polarity(m) =
  { "<domain>|<target>|<package>" = default-features; }   # externals only
activationSensitive(m) =
  any feature value v in m.features where
    v matches "dep:<ext>" with <ext> external, OR
    v matches "<ext>/<feat>" with <ext> external;
```

`activationSensitive` is deliberately over-broad (it ignores whether the feature
is actually enabled) and therefore conservative.

### 4.4 Internal path-dep components

Build a graph over members from `internal(m)` path entries (normalized to repo
paths) and take connected components. **Shards are unions of whole components.**
This closes internal path deps (Plan C P2-3) and guarantees a shard's filtered
source contains every path dep its members need.

### 4.5 Shard key and shard modes

```nix
shardKey(m) =
  if activationSensitive(m) then "solo:<member>"          # REWEAVE-S
  else hash (host, polarity(m), nativeInputsProfile(m));  # REWEAVE-P
```

- `REWEAVE-P` (default): members with the same polarity vector, host, and
  native-input profile share. In this repo the polarity vector is uniform for
  the externals in play, so all non-sensitive members collapse to **one shard**
  (Plan C's REWEAVE-1 is the degenerate sub-case).
- `REWEAVE-S` (`shardKey = full external signature`): the Plan B endpoint, used
  as the per-member fallback and available as `shardMode = "signature"`.
- `shardMode = "perMember"`: each member its own shard; rewrite is a no-op; this
  is the migration/rollback shape.

The emitter must never split a component; the planner computes shards as a union
of components and then applies the key.

### 4.6 Union of externals

For shard `S`, merge `external(m)` over `m ∈ S`, per `(domain, target)`:

```nix
merge a b = {
  version           = a.version or b.version;                 # see version families below
  package           = a.package or b.package or key;
  features          = unique ((a.features or []) ++ (b.features or []));
  default-features  = (a.default-features or true) || (b.default-features or true);  # identity inside a shard
  optional          = (a.optional or false) && (b.optional or false);                # safe: no external dep: in a shared shard
  path              = null;                                                            # externals only
};
```

Version families:

1. Resolve each member's declared `key` to its locked `(name, version)` where
   possible; if a shard contains two version families of the same package
   `name`, **split the shard by family** (conservative, keeps the emitter
   simple). `Cargo.lock` has 30 multi-version names in the current union, but
   the repo's members do not disagree on a _direct_ external family; the check
   is cheap insurance.
2. For an injected package that member `m` does not itself declare, emit
   `version = "=<locked version>"`. This is the anti-downgrade pin.
3. If the member declares it, keep the member's own key and requirement, and
   union features.

### 4.7 Canonical member manifest

```nix
canonicalManifest(m, S) =
  (rawManifest m)
  // { dependencies         = table (U S) "normal" "."; }
  // { "build-dependencies" = table (U S) "build"  "."; }
  // { "dev-dependencies"   = table (U S) "dev"    "."; }
  // { target               = targetTables (U S); }        # preserve per-cfg mapping
```

- `[package]`, `[lib]`, `[[bin]]`, `[features]`, edition, and the member's own
  `internal(m)` entries are preserved verbatim.
- External entries are flattened (no `workspace = true`) so the generated
  manifest is self-describing; `[workspace.package]` is still present in the
  member source's root manifest for `version.workspace = true` etc.
- Exactly **one key per `(package, version family)`** is emitted. If the member
  uses a renamed key, emit the union entry under that key; additional families
  that the member does not use are not emitted in the v1 conservative mode (they
  were excluded by the family split).

### 4.8 Plan output

```nix
{
  members = [{ dir, name, external, internal, polarity, activationSensitive,
               profile, shard, degrade, roots }];
  shards  = [{ key, label, members, memberDirs, components,
               union, canonical = { <dir> = <manifest attrset>; } }];
  memberShard = { "<dir>" = "<shard key>"; };
  warnings = [ "..." ];
  version = "1";
}
```

Deterministic ordering everywhere (sort member dirs, feature lists, input
lists). Exposed as `passthru.rustPlan` and `nix eval .#rustPlan`.

**Planner size budget:** ~250–350 lines of Nix. If it exceeds ~400, stop and
re-derive; complexity is a hard quality goal.

---

## 5. Emitter: exact mechanisms and cargo invocations

### 5.1 Sources

- **Member source** (`buildSrc`): unchanged from L —
  `mkCargoWorkspaceSource { src; projectDir = m; deps = internal dirs; }`,
  filtered to `[m] ++ internalClosure(m)` and named `cargo-workspace-source`.
  `.rs` locality is preserved: only the edited member's source hash changes.
- **Shard source** (base):
  `mkWorkspaceSourcePath { src;
  selectedDirs = S.memberDirs; }` — real member
  dirs (dummified by crane at eval), named `cargo-workspace-source` so the
  unpack dir matches.
- **Canonical manifest**:
  `unionManifest = pkgs.craneLib.writeTOML "Cargo.toml" plan.shards.S.canonical.<dir>`.
  This is a derivation referenced only at build time (no IFD).

### 5.2 Base

```nix
shardBase(S) =
  craneLib.buildDepsOnly {
    dummySrc = craneLib.mkDummySrc { src = shardSource S; };
    pname = "abird-rust-${label S}";              # → …-deps
    version = "0.1.0";
    cargoExtraArgs = "--locked --offline --workspace";
    prePatch = cargoWorkspaceMembersPrePatch { members = S.memberDirs; };  # root [workspace].members := S
    inherit (craneCargoLockAttrs) cargoLockContents;
    inherit (shared) cargoVendorDir;
    nativeBuildInputs = S.nativeBuildInputs;      # from the shard key profile
    buildInputs = S.buildInputs;
    env = { CARGO_NET_OFFLINE = "true"; };
  };
```

- `buildDepsOnly` runs `cargo check --all-targets`, `cargo build`,
  `cargo test
  --no-run`, so normal, build/host/proc-macro, dev/test, bench,
  and example units are primed; `doCheck = true`; `CRANE_BUILD_DEPS_ONLY = 1` is
  set by crane.
- `--locked` is safe here: only the member list changes; no dependency edges are
  added. Verified (`tmp/design-f/locktest2`).
- `prePatch` runs on the unpacked dummy source in `mkCargoDerivation`; factor
  the existing `cargoWorkspacePrePatch` awk into
  `cargoWorkspaceMembersPrePatch { members }` (the current helper assumes a
  non-null `projectDir` and is guarded in `composeCargoWorkspacePrePatch`, so it
  cannot be called directly with `projectDir = null`). The member path keeps
  using `cargoWorkspacePrePatch { projectDir; deps; }` unchanged.
- `shardBase` is computed once per shard from canonical inputs, so Nix
  hash-conses one derivation per shard.

### 5.3 Member layer and package

```nix
memberLayer(m) =
  craneLib.cargoBuild (compileOnly craneCommonAttrs(m) // {
    src = buildSrc m;                             # real per-member source
    prePatch = joinLines [
      (cargoWorkspacePrePatch { projectDir = m.dir; deps = internalDirs m; })
      "install -m u+w -D ${unionManifest m} ${m.dir}/Cargo.toml"
      userPrePatch
    ];
    cargoArtifacts = dependencyArtifacts m;       # shardBase or internal layers
    cargoExtraArgs = "--offline -p ${pname m}";
    doInstallCargoArtifacts = true;
    env = { CARGO_NET_OFFLINE = "true"; };
    nativeBuildInputs = profileFor m;             # same profile as its shard
  });

pkg(m) = craneLib.buildPackage (craneCommonAttrs(m) // {
  inherit (memberLayer m) src prePatch nativeBuildInputs;   # same canonical source
  cargoArtifacts = memberLayer m;
  cargoExtraArgs = "--offline -p ${pname m}";
  env = { CARGO_NET_OFFLINE = "true"; };
});
```

- The member uses `--offline` (not `--locked`) because the canonical manifest
  adds dependency edges for injected externals. Every injected edge is pinned
  `=locked`, so cargo has no reason to move any version.
- `CARGO_NET_OFFLINE = "true"` is what makes `buildPackage`'s install-time
  `cargo metadata` (which does **not** pass `--offline`) work in the sandbox and
  avoid any lock rewrite (fact 3).
- `compileOnly` strips `postInstall`, `nativeCheckInputs`, `checkEnv`, and other
  non-compile attrs from the artifacts-only layer (review P2-a). The deployed
  `buildPackage` keeps the full attrs.

### 5.4 Checks

```nix
checks.fmt   = craneLib.cargoFmt (craneCommonAttrs(m));      # real canonical source
checks.lint  = craneLib.cargoClippy (mkCheckAttrs {
                 cargoArtifacts = memberLayer m;
                 cargoExtraArgs = "--offline -p ${pname}";
               });
checks.test  = craneLib.cargoTest (mkCheckAttrs {
                 cargoArtifacts = memberLayer m;
                 cargoExtraArgs = "--offline -p ${pname}";
                 doCheck = true;
               });
```

The base's `doCheck = true` primed the shard's dev/test units, so `checks.test`
and the deploy-time `cargo test` reuse them (fixes review P2-e on the REWEAVE
path). `nativeCheckInputs` remain on the member/check layer; their profile is
part of the shard key so the base has what it needs to run
`cargo test --no-run`.

### 5.5 Internal dependencies

- `dependencyArtifacts(m)`:
  - no internal deps → `shardBase(S(m))`;
  - exactly one → that dependency's `passthru.memberLayer` (L's existing special
    case; no join);
  - two or more → `mkCargoArtifactsJoin` (full-archive union; probe required,
    review P2-h).
- The member's canonical manifest keeps its own internal path-dep entries
  verbatim, so a feature request on an in-repo crate is preserved. If a
  dependent requests features on an internal crate that differ from that crate's
  own member layer, cargo recompiles the internal crate inside the dependent's
  layer. This is bounded to in-repo crates, is correct, and is the one residual
  REWEAVE does not remove without forcing internal feature unions (a future,
  optional extension).

---

## 6. Lock, vendor, and fingerprint rules

| rule               | mechanism                                                                                                                                                             |
| ------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| One vendor dir     | `craneLib.vendorCargoDeps` from the unchanged `Cargo.lock`; same derivation for every base/member/check.                                                              |
| Base lock          | `--locked --offline`; only the member list is rewritten, so the lock is preserved.                                                                                    |
| Member lock        | `--offline`; injected externals pinned `=<locked version>`; `CARGO_NET_OFFLINE=true` for install-time metadata.                                                       |
| No new packages    | `U(S)` is built only from declarations already in member manifests, so every injected package is already in the lock/vendor.                                          |
| No downgrade       | Exact `=x.y.z` pins + V4 (`cargo metadata --offline` diff vs the committed lock must show no version change for any used package).                                    |
| Source basename    | Both shard and member sources are named `cargo-workspace-source`, so both unpack to `/build/cargo-workspace-source` (fact 2).                                         |
| Fingerprint inputs | Features equal by construction; profile/rustflags shared via `craneCommonAttrs`; native-input profile is in the shard key; one vendor path; matching unpack dir.      |
| Artifacts          | `memberLayer` publishes `target.tar.zst`; the deployed `buildPackage` inherits it and does not export artifacts, so no dependency archive enters the runtime closure. |

The member's own canonical manifest changes that member's unit hash (desired)
and does not enter any external unit's fingerprint.

---

## 7. Dev-dependencies and tests

- The shard base (`doCheck = true`) primes dev-deps and test targets for every
  shard member. This is a deliberate carry-over from L's design and fixes the
  deploy-time test-target recompile (review P2-e).
- `U(S)` includes `[dev-dependencies]` and `[target.<cfg>.dev-dependencies]` as
  separate domains, so dev feature unification is handled by the same union
  mechanism.
- Resolver 3 keeps dev-deps out of the normal feature domain; the base's normal
  units come from the `cargo build` phase before the test phase, and the
  member's `cargo build -p m` matches them.
- If dev-dep churn later proves noisy, a separate test-only base shard is an
  isolated extension.

---

## 8. Platform gating and the native-input seam

- **Per-host plan.** The composition layer supplies the host-selected member set
  (from `meta.platforms`). A member excluded on a host never enters that host's
  shard, so a Darwin-only member cannot break a Linux base (review P1-A).
- **Target tables preserved** per `cfg`, so a member's `cfg(windows)` deps never
  activate on Linux.
- **Native-input profile.** Each member is assigned a canonical profile (its
  build inputs plus the check inputs its dev/test units need). The profile is
  part of the shard key; members with different profiles never share. The shard
  base receives the profile's inputs. This closes the fingerprint gap Plan B's
  signature left open and the native-input gap L left unfiltered.
- `nativeCheckInputs` (e.g. `rsync` for agent tests) stay on the member/check
  layer; the _build_ inputs needed to compile dev-deps are in the profile and on
  the base.

---

## 9. Diagnostics, degradation, and observability

- `passthru.rustPlan` on every package: shard key, shard members, `U(S)`,
  `canonicalManifest`, injected externals (with pins), activation flags, and the
  chosen mode.
- `flake.rustPlan` output prints the partition, union sizes, predicted external
  compile counts, and the dedup/churn decision for `nix eval`.
- `lib.warn` (never throw) at every degrade: non-expandable glob, manifest parse
  failure, `activationSensitive` fallback, version-family split, `[patch]`
  conflict, `craneLib == null`, non-member `projectDir`, `projectDir = "."`.
- Degradation targets:
  - planner failure for a member → that member's shard degrades to
    `perMember`/L; the rest of the plan still applies (unless the root manifest
    is unreadable, in which case the whole repo degrades to L as today);
  - `shardMode == "l"` escape hatch → `useUnionRewrite = false` restores landed
    L bit-for-bit;
  - non-member / isolated → legacy per-package path unchanged.
- The **freshness gate** (§11) is the failure detector. It is the contract that
  converts any projection error into a CI failure rather than silent residual.

---

## 10. Dep-churn and `.rs`-locality behaviour (honest)

| change                                                | one-shard (uniform polarity, this repo default)                                                      | multi-shard (REWEAVE-P with differing polarity/profiles) |
| ----------------------------------------------------- | ---------------------------------------------------------------------------------------------------- | -------------------------------------------------------- |
| `.rs` content in `m`                                  | member source + `memberLayer(m)` + `pkg(m)` + dependents; base byte-stable                           | same                                                     |
| add/remove a `.rs` file                               | member source changes; base stability to be confirmed by spike S7 (crane launders manifests at eval) | same                                                     |
| `Cargo.toml` external edit in `m`                     | `U(S)` changes ⇒ base ⇒ all member layers re-run                                                     | only `m`'s shard base and its members re-run             |
| `Cargo.toml` internal/path edit in `m`                | component changes; shard membership may change; base may change                                      | as one-shard, within the component                       |
| `Cargo.lock` / `[workspace.dependencies]` / `[patch]` | global (correct — these are genuinely global)                                                        | all shards                                               |
| new member                                            | global (root manifest + lock)                                                                        | new shard + root/lock                                    |

The one-shard manifest-churn cost is L's existing behaviour. It is the price of
maximal dedup; the shard knob, and the deferred canonical base, let an operator
trade it. This is stated up front and is not claimed away.

---

## 11. The freshness gate

`checks.union-fresh-<pname>` (or a single repo-level `checks.unionFresh`) for
each shard member:

1. Build `shardBase(S)`.
2. Run the member layer with `cargo build -p m --message-format=json` against
   the inherited artifacts.
3. Assert that **no** `compiler-artifact` message has `fresh = false` for a
   package id that is not a workspace member. Equivalently, assert the member
   layer's log contains no `Compiling <external>` line.
4. Additionally run `cargo tree -e features --offline` for the base's selected
   closure and for `-p m`, and diff the feature sets for the packages that
   matter (or at minimum for every package with an explicit
   `default-features = false` in the root table); report any divergence.

Any under-approximation in the planner (missing declaration, feature activation,
version family, or a fingerprint gap) makes step 3 non-empty and fails the
check. This is the guarantee Plan A lacked and Plan B only approximated by
construction.

---

## 12. Complexity and maintenance budget

| component                                | size           | maintenance note                                                                                                              |
| ---------------------------------------- | -------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `lib/flake/rust-workspace.nix` (planner) | ~250–350 lines | pure functions; no crane/pkgs; fully unit-testable with eval tests                                                            |
| `pkg-helper.nix` emitter delta           | ~150 lines     | parameterize `mkSharedRustDepsBase`, add `unionManifest` to `prePatch`, add shard key to `cargoArtifacts` selection, add gate |
| new eval tests                           | ~100 lines     | `lib/flake/tests`                                                                                                             |
| new derivation kind                      | 0              | reuses `buildDepsOnly`/`cargoBuild`/`checks`                                                                                  |

Maintenance rules:

- The planner never resolves features/versions; if a change would require semver
  or a feature fixpoint, stop and degrade that member to `perMember`/REWEAVE-S.
- All lists are canonicalized (sorted, deduped) so hash-consing is stable.
- The public API grows only optional arguments; defaults reproduce L.

---

## 13. Staged migration

1. **F0 — planner diagnostic.** Land `lib/flake/rust-workspace.nix` and
   `flake.rustPlan`; no build change. Validate `U(M)`, polarity, activation
   flags, and predicted compile counts against the lock and the measured L
   residual.
2. **F1 — singleton shards (safe wiring).** Point `prefixNode` at
   `shardBase({m})` (a `-p m` base) and wire the member list rewrite into the
   base. No union rewrite. Verify cross-source reuse and the gate. This proves
   the plumbing and the gate with the smallest change.
3. **F2 — union rewrite (headline).** Enable `REWEAVE-P` (one shard here) and
   the canonical-manifest `prePatch`; measure zero external `Compiling` in every
   member layer and green `union-fresh`.
4. **F3 — sharding and seams.** Enable polarity/profile sharding, platform
   gating, native-input profiles, eval tests, and diagnostics.
5. **F4 — optional canonical base.** Make the base depend on `U(S)` rather than
   raw manifests by splicing only dependency tables (never `extraDummyScript`);
   confirm non-external manifest edits become base-local. Add the fan-in join
   probe.
6. **Fallback.** `useUnionRewrite = false` (default false until F2 lands)
   restores L exactly.

Seams kept stable: `src`/`dummySrc` injection, `cargoArtifacts` injection, a
shard label even in L, and untouched `checks`/`pkgOps`/`devShell`/`passthru`
wiring.

---

## 14. Validation gates and required spikes

### 14.1 Spike gates (must pass before implementation proceeds)

- **S1 — Union forcing.** With two real members, a shard base built
  `--workspace` over S and a member canonical-manifest build `-p m` recompiles
  **no** external; the un-rewritten member reproduces the L residual. (Plan C
  spike 2 already showed this in `tmp/design-f/exp`; reproduce in-repo.)
- **S2 — Filtered shard base + root rewrite.** A base whose source is filtered
  to a subset S and whose root `members` is rewritten to S builds with
  `--locked --offline --workspace` and leaves `Cargo.lock` unchanged. (Fixes
  Plan C B2; verifies `prePatch` runs on `buildDepsOnly`.)
- **S3 — Lock additive edge + pin + metadata.** A member canonical manifest that
  injects a shard-mate external pinned `=locked` builds `--offline` with exactly
  the additive lock edge it needs; `CARGO_NET_OFFLINE=true` lets
  `buildPackage`'s `cargo metadata` install succeed; no used version changes.
- **S4 — Activation fallback.** A member with
  `[features] default =
  ["dep:ext"]` is placed in a solo shard; the gate
  catches a deliberately forced shared shard.
- **S5 — Native-input profile.** Two members differing only in native inputs get
  different shard keys; each base resolves and reuses correctly.
- **S6 — Gate efficacy.** Deliberately omit one direct external declaration from
  `U(S)` and confirm `union-fresh` fails (non-empty external `Compiling`).
- **S7 — `.rs` add/remove base stability.** Append/remove a `.rs` file and a
  `src/bin/*.rs`; confirm the shard base drv is byte-stable (crane launders
  manifests at eval), documenting any exception.
- **S8 — Fan-in join.** A member with two internal deps builds via
  `mkCargoArtifactsJoin` and reuses both dependencies' layers.

### 14.2 Standard gates

- **V1 no IFD:** every package evaluates with
  `--option allow-import-from-derivation false`; the new module has no unguarded
  `readFile`/`readDir`/`pathExists`.
- **V2 zero residual:** `union-fresh` green for every member;
  `nix derivation
  show -r` shows the shard-base → member edges.
- **V3 `.rs` locality:** a member `.rs` content edit leaves every shard base drv
  byte-identical and changes only the edited member and dependents.
- **V4 lock fidelity:** `cargo metadata --offline` inside a member build shows
  no version change for any used package.
- **V5 polarity:** for `reqwest`/`ssh-key` users, `cargo tree -e features` shows
  defaults off and no default-only dependency; a repo-wide audit of
  `default-features = false` crates passes.
- **V6 manifest churn:** edit one member `Cargo.toml`; in `perMember`/sharded
  mode only its shard changes; in one-shard mode document the global rebuild as
  expected.
- **V7 fingerprint alignment:** base and member unpack to
  `/build/cargo-workspace-source`; one vendor dir.
- **V8 closure isolation:** `nix path-info -r` on deployed packages shows no
  artifact archive.
- **V9 eval tests:** partition deterministic; every member in exactly one shard;
  components not split; no shared-shard member is `activationSensitive`;
  degrade-without-throw; join evaluates.
- **V10 correctness:** `nix flake check`, every package builds, the isolated
  child flake is unaffected.
- **V11 normalization guard:** an eval assertion that a member does not
  re-declare feature sets that would re-split the cache under
  `[workspace.dependencies]` (review P2-f), or a warning if it does.

---

## 15. The honest "compiles once" statement

What REWEAVE claims:

- Every **external** crate compiles once per `(host, shard key)` in the shard
  base. In the current repo (uniform polarity, no external `[features]`
  activation, uniform native inputs), that is **one compile per external
  repo-wide**.
- Every **member** layer adds zero external compiles, verified by `union-fresh`.
  If a projection gap exists, the gate fails rather than silently recompiling.
- Every in-repo member compiles once in its `memberLayer`; dependents inherit
  that layer. An in-repo crate may recompile in a dependent's layer if the
  dependent requests different features on it (bounded, in-repo only).
- `.rs` content edits stay local to the edited member and its dependents.

What REWEAVE does **not** claim:

- Absolute exactly-once for arbitrary workspaces; correctness and reuse depend
  on the union being exact, which the gate verifies per build, not on a theorem.
- That transitive `default-features` polarity conflicts are invisible and
  harmless: they are invisible to pure eval by construction (`Cargo.lock` has no
  feature data) and are accepted as additive widening, with a polarity audit.
- That manifest edits are always local: in the one-shard default they are global
  (the same as L); sharding buys locality at a dedup cost.
- Cross-feature-change hash stability; rewiring on change remains accepted.
- That the legacy / non-workspace / isolated paths gain anything.

---

## 16. Standing review findings folded in, and doc corrections

Lands with F (and some can land now):

- **P1-A native-input seam:** `shardBase` takes `members`, `nativeBuildInputs`,
  `buildInputs`, `nativeCheckInputs`; host filtering is in the planner. Closes
  the unfiltered-`--workspace` single point of failure.
- **P1-B diagnostics:** `lib.warn` at every degrade trigger;
  `passthru.rustPlan`; `flake.rustPlan`. Closes the silent-mode-selection
  finding.
- **P1-C docs:** mark direct feature normalization **landed**; state the "union
  at root, members bare `{ workspace = true }`" policy; keep the
  transitive-union residual open and now explicitly fixed by REWEAVE's rewrite.
  Update `design-l-implementation-2026-09.md`,
  `rust-build-graph-decision-2026-09.md`, and
  `rust-workspace-build-graph-2026-09.md`.
- **P2-a:** `memberLayer` receives a compile-only filtered attrset (no
  `postInstall`/`nativeCheckInputs`/`checkEnv`).
- **P2-b:** one validated `internalDeps` list drives both source dirs and
  artifact layers; the guard is forced on every shape.
- **P2-c:** normalize then `unique` `resolvedDeps` and dependency layers.
- **P2-d:** thread the resolved lock through instead of rejecting a
  derivation/table lock in workspace mode.
- **P2-e:** on the REWEAVE path the base primes test targets; document the
  legacy-path trade.
- **P2-f:** add the normalization guard (V11).
- **P2-g:** add `lib/flake/tests` eval assertions (V9).
- **P2-h:** probe `mkCargoArtifactsJoin` (S8); consider a symlink-only join if
  the first multi-edge member appears.
- **`.rs`-stability caveat:** state that _content_ edits are stable and that
  add/remove behaviour is verified by S7; do not over-claim.
- **Doc over-claims to fix:** `rust-workspace-build-graph-2026-09.md` says
  "Every dependency … compiled once repo-wide" without the residual/feature
  qualification; `cargo-workspace-2026-04.md` says source edits keep the deps
  artifact reusable (corrected by the review); `design-l-implementation` says
  W10 is "partially deferred" (it landed); the `exportCargoArtifacts` note does
  not exist in the tree; the split code span in §Steps 3 should be joined.
- **Folded into this plan:** the residual is attributed to selection-based
  unification, and the fix is the union rewrite, not per-demand groups.

---

## 17. Remaining risks

1. **Projection fidelity.** The planner merges declarations; an unanticipated
   Cargo construct (unusual aliases, `artifact`/`lib` deps, duplicate-key merge
   semantics) could under-approximate. Mitigation: conservative projection,
   `activationSensitive` solo shards, version-family splits, and the fail-closed
   gate.
2. **Transitive polarity widening.** Invisible without IFD. Mitigation: polarity
   audit (V5), documented policy, and the freshness gate catching the resulting
   recompile.
3. **One-shard manifest churn.** Accepted. Mitigation: shard knob and deferred
   canonical base.
4. **Internal-crate feature divergence.** Bounded residual. Mitigation:
   document; future optional internal union.
5. **Planner complexity creep.** Hard budget ~400 lines; otherwise degrade.
6. **Cargo-version drift.** The mechanism relies on cargo's documented
   selection-based unification and workspace inheritance; pinned toolchain and
   the gate catch regressions.
7. **Nix hash-consing drift.** Canonicalize and sort all planner outputs; eval
   tests assert stable plan hashes.

---

## 18. References

- `.agents/docs/plans/design-f-build-graph-2026-09.md` — draft adjudicated here.
- `.agents/docs/plans/rust-workspace-build-graph-2026-09.md` — L/F handoff.
- `.agents/docs/plans/design-l-implementation-2026-09.md` — landed L mechanics.
- `.agents/docs/notes/tooling/rust-build-graph-review-2026-09.md` — P1/P2
  findings folded in above.
- `.agents/docs/notes/tooling/rust-build-graph-decision-2026-09.md` — decision
  log and measured residual.
- `tmp/design-f/plan-b.md`, `tmp/design-f/critique-b.md`,
  `tmp/design-f/plan-c.md`, `tmp/design-f/critique-c.md` — competing designs and
  adversary evidence.
- `lib/flake/pkg-helper.nix` — `mkWorkspaceSourcePath` (`67`),
  `mkCargoWorkspaceSource` (`102`), `rustWorkspaceMembers` (`142`),
  `mkRustWorkspaceSource` (`167`), `mkSharedRustDepsBase` (`179-195`),
  `mkCargoArtifactsJoin` (`198-219`), `cargoWorkspacePrePatch` (`235`),
  `mkRustDerivation` workspace mode (`2235`+), `memberLayer` (`2400-2411`).
- Crane source rev `73b9805`: `lib/buildDepsOnly.nix`,
  `lib/mkCargoDerivation.nix`, `lib/mkDummySrc.nix`,
  `lib/writeTOMLViaCraneUtils.nix`.
- Experiment artifacts:
  `tmp/design-f/{exp,attack,opt,pathtest,mv,unused,reuse,
  residual,locktest2,wsfeat,dfinherit,resolv}`.
