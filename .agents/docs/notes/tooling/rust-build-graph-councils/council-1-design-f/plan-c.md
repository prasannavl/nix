# Plan C for Design F — **REWEAVE**

> Force the feature union by **rewriting each member's dependency declarations**
> to its shard's computed union, then build one (or a few) real dependency bases
> over that same union. No synthetic crate, no aggregate member, no new lock
> package. Every external compiles once; `.rs` edits stay local; the public
> `mkRustDerivation` API is untouched.

Status: design only (no implementation). Alternative to Plan A ("F-union",
synthetic `crane-union` aggregate) and Plan B ("F-cluster", per-signature real
selections, `tmp/design-f/plan-b.md`), and to the landed Design L. Plan B is
already on disk; this plan is written against it and against the Plan A critique
in the task brief.

- Repo under study: `/home/pvl/src/nix` (5 members, 372 locked packages, 338
  distinct names, 30 multi-version names).
- Hard requirements: no IFD, `.rs` edits local, public API unchanged
  (`pkgHelper.mkRustDerivation { projectDir; … }`), scalable to 24 members,
  maintenance-light.
- Landed baseline: `mkSharedRustDepsBase` (`lib/flake/pkg-helper.nix:179-195`),
  `memberLayer` (`pkg-helper.nix:2400-2411`), `cargoWorkspacePrePatch`
  (`pkg-helper.nix:235`).

---

## 0. Executive summary: Plan C is the continuum between A and B

All three plans need the same thing: a member build whose **selection** resolves
each external to the same feature set as the base it inherits. They differ only
in _how_ they change the member's selection.

- **Plan A** changes it by co-selecting a synthetic aggregate
  (`-p m -p crane-union`). One fixed union for everyone.
- **Plan B** does not change it; it changes the _base_ to be a real `-p`
  selection that is byte-identical to the member's own signature. Exact, but two
  members can share a base only when their full signature is equal.
- **Plan C** changes it by rewriting the member's manifest so its declared
  requirements _are_ the shard union. The base is a real selection over the same
  rewritten manifests (or over the shard's real members). This makes the base
  and the member agree by construction, regardless of how different their
  original signatures were.

The single knob is the **partition** (the "shard key"):

```text
shard key = full signature   →  Plan B (no manifest synthesis, no widening)
shard key = polarity vector  →  Plan C (this document: maximal safe sharing)
shard key = constant         →  Plan A-like global union, but no stub crate
shard key = per member       →  Design L as landed (max churn, max isolation)
```

Rewriting the member to its shard union makes **any** partition exact-once
_within a shard_: the base and the member resolve the identical dependency
table. So Plan C can choose the partition purely for churn/dedup, exactly as
Plan B claims, but it is no longer _forced_ into singleton shards when
signatures differ. In this repo, where all five signatures differ but the
`default-features` polarity is uniform, Plan C collapses to **one global base
with zero residual and zero widening** — the best of A and B.

**Plan C's headline numbers for this repo:** 1 external base (367 packages, the
true union), 0 residual recompiles in every member layer, 0 synthetic crates, 0
new lock packages.

---

## 1. Constraints and goals

Hard:

- **No IFD.** The planner reads only eval-visible files (`Cargo.toml`,
  `Cargo.lock`). All generated manifests are built by derivations consumed at
  build time, never read at eval time.
- Keep per-package `default.nix` calling
  `pkgHelper.mkRustDerivation { projectDir; … }`.
- A member's real build must still resolve its own closure. Correctness may not
  depend on the planner being a perfect Cargo solver.

Quality:

- Every external compiled once, in the union base.
- `.rs` edit to `m` invalidates only `m` and its dependents.
- A dependency-manifest change rebuilds only the affected shard base (C2) and
  its dependents; with one global shard it rebuilds the base (C1, same as L).
- One place to add a member; no hand-synced edge lists.
- Legible, dumpable generated manifests (`passthru`/`rustPlan`), so the build
  can be debugged against the repo manifests.

---

## 2. Model

### 2.1 What the union is

Let `M` be the host-selected workspace members. For each member `m`, `decls(m)`
is its dependency declaration table across every Cargo domain:

- `dependencies`, `build-dependencies`, `dev-dependencies`
- `target.<cfg>.{dependencies,build-dependencies,dev-dependencies}`
- `workspace = true` entries resolved against `[workspace.dependencies]`

The **union** `U(M)` is the per-domain, per-target merge of `decls(m)` over
`m ∈ M` with:

- `features`: set union (Cargo features are additive);
- `default-features`: logical OR across declarations;
- `optional`: logical AND (only optional if optional everywhere);
- `version`/`package`/`path`: one entry per `(package, version-req)`; distinct
  version families become distinct entries.

`U(M)` is a _declaration table_, not a resolution. Cargo resolves it.

### 2.2 Why unioning declarations is enough (no resolver reimplementation)

Cargo's feature resolution is the least fixpoint of the union of feature
requirements over the **selected** package graph. Two invocations that select
the same graph from the same root requirement table resolve identical features.
`--workspace` over `decls(M)` selects the closure of `U(M)`; a rewritten member
`m'` whose table is `U(M)` selects the same closure. Therefore:

- the **base** built over manifests carrying `U(M)` and the **member** built
  over the rewritten manifest both resolve extervals to the same features;
- no evaluator-side closure, demand lattice, or semver matcher is needed.

This is the central simplification over Plan A's planner: we never compute which
package is reachable from where; we copy the **root declarations** and let Cargo
do the fixpoint. Copying all roots of a member set is what forces the union onto
any member of that set.

### 2.3 What a shard is

A **shard** `S ⊆ M` is a member subset chosen by a partition function. Plan C
computes `U(S)` and rewrites every `m ∈ S` to `U(S)`. The base for the shard is
a real selection over `S` (or over generated manifests carrying `U(S)`).

Invariants:

- `S` is **closed under internal (path) dependencies**: if `m ∈ S` and `m`
  path-depends on `n ∈ M`, then `n ∈ S`.
- Shards are disjoint and cover `M`.
- `hello-rust` (empty closure) is allowed to be its own trivial shard, or to
  share; it contributes nothing to `U`.

### 2.4 Partition functions (the spectrum)

| name      | shard key                                                | manifest rewrite | sharing      | polarity                              |
| --------- | -------------------------------------------------------- | ---------------- | ------------ | ------------------------------------- |
| REWEAVE-1 | constant (`M`)                                           | yes              | maximal      | OR (widens only if a member disables) |
| REWEAVE-P | polarity vector (per package, `default-features` on/off) | yes              | maximal safe | preserved                             |
| REWEAVE-S | full signature (Plan B's key)                            | no-op            | Plan-B level | preserved                             |
| REWEAVE-T | per member (each its own shard)                          | no-op            | none         | preserved                             |

Plan C's recommended default is **REWEAVE-P**: group members whose
`default-features` polarity agrees on every package, so the union never flips a
polarity; inside a shard, feature-set differences are handled additively, which
is exactly the policy the repo already adopted in the landed W10 root
normalization. REWEAVE-1 is the degenerate "one base" mode used when the
polarity vector is uniform (this repo). REWEAVE-S/T are the safe fallbacks and
the migration endpoints.

### 2.5 Direct declarations vs Plan B's signature

Plan B keys the shard on the full canonical signature. Plan C keys it on the
weaker property that actually matters for correctness of a union — polarity —
and lets the rewrite absorb every other difference. Two members with different
features but the same polarity can share; under Plan B they cannot. This is the
entire reason Plan C reaches one base here while Plan B degenerates to five
singleton bases.

---

## 3. Architecture

```text
         pure eval (no IFD)                          build time
root Cargo.toml + member manifests            ┌──────────────────────────┐
+ Cargo.lock                                  │ union base(S):           │
      │                                       │  buildDepsOnly over      │
      ▼                                       │  manifests carrying U(S) │
rust-workspace planner                        │  --offline --workspace   │
├─ decls(m) per domain/target                 └────────────┬─────────────┘
├─ polarity(m)                                    cargoArtifacts
├─ shard key → shards S                    ┌─────────────────┘
├─ U(S) = merge decls(S)                   ▼
├─ canonicalManifest(m) = m // U(shard(m)) memberLayer(m):
└─ internal path-dep closure               rewrite m → U(shard(m))
      │                                     cargo build --offline -p m
      ├─ writeTOML(canonicalManifest) ──────┤  (member's real source,
      │                                     │   generated manifest in
      └─ mkWorkspaceSourcePath(S) ──────────┘   prePatch)
                                                   │
                                            buildPackage / checks
```

Two module boundaries, mirroring Plan B and the Design F document:

- `lib/flake/rust-workspace.nix` (**new**, pure): file contents → shards,
  unions, canonical manifests. No `pkgs`, no crane, no derivations.
- `lib/flake/pkg-helper.nix` (**modified**): consumes the plan, parameterises
  the existing seams (`mkWorkspaceSourcePath`, `mkSharedRustDepsBase`,
  `cargoWorkspacePrePatch`, `memberLayer`). Public API unchanged.

No synthetic workspace and no synthetic member are ever created. Every generated
manifest describes a **real** member (same name, same path, same targets),
differing only in its dependency tables.

---

## 4. The planner (pure eval)

### 4.1 Inputs

Only evaluator-visible paths:

- root `Cargo.toml` (`[workspace]`, `[workspace.dependencies]`,
  `[workspace.package]`, `[patch]`);
- each member `Cargo.toml`;
- `Cargo.lock` (for diagnostics and version pins, not for resolution).

No derivation is read, so no IFD. Glob members are expanded with
`builtins.readDir` on the path source, or the whole repo degrades to L (as
today) with a `lib.warn`.

### 4.2 Resolving a declaration

For each entry in each domain/target table:

```nix
resolve = ws: key: decl:
  if decl.workspace or false then
    let w = ws.${key} or {}; in
    decl // w // {
      version = decl.version or w.version or null;
      package = decl.package or w.package or key;
      features = unique ((w.features or []) ++ (decl.features or []));
      default-features =
        if decl ? default-features then decl.default-features
        else if w ? default-features then w.default-features
        else true;
      optional = decl.optional or w.optional or false;
      path = decl.path or w.path or null;
    }
  else decl // {
    features = unique (decl.features or []);
    default-features = decl.default-features or true;
    optional = decl.optional or false;
  };
```

The `if decl ? default-features` override was verified against Cargo:
`[workspace.dependencies] x = { default-features = false, … }` plus a member
`x = { workspace = true, default-features = true }` resolves with defaults on;
workspace `false` plus member `false` resolves with defaults off.

### 4.3 Merge

```nix
merge = a: b: {
  version = a.version or b.version;
  package = a.package or b.package;
  features = unique ((a.features or []) ++ (b.features or []));
  default-features = (a.default-features or true) || (b.default-features or true);
  optional = (a.optional or false) && (b.optional or false);
  path = a.path or b.path;                 # internal deps: last wins / assert equal
};
```

Entries are keyed by `(domain, target, package, version)`; `version` is the
declared requirement string. Distinct version families (`rand 0.8` vs
`rand 0.9`) stay distinct. `path` entries are kept verbatim and never merged
with external entries.

### 4.4 Polarity vector (REWEAVE-P)

```nix
polarity(m) = { "<domain>|<target>|<package>" = default-features; … }
shardKey(m) = builtins.hashString "sha256" (builtins.toJSON (polarity m));
```

Polarity is only defined for packages a member actually requests (directly or
through `workspace = true`). Transitive polarity conflicts are invisible to pure
eval; §6.3 and §11 cover detection and fallback.

### 4.5 Canonical manifest

```nix
canonicalManifest(m, S) =
  let u = U(S); in
  (memberManifest m)
  // { dependencies = table u "dependencies" "."; }
  // { "build-dependencies" = table u "build-dependencies" "."; }
  // { "dev-dependencies" = table u "dev-dependencies" "."; }
  // { target = targetTables u; }
```

- `[package]`, `[lib]`, `[[bin]]`, `[features]`, and `path` dependencies are
  preserved from the real member, so the real source still builds its targets.
- `workspace = true` entries are flattened to explicit `version`/`features` in
  the generated manifest, so the generated workspace need not carry
  `[workspace.dependencies]` for the build (the root manifest still carries it
  for `[workspace.package]` inheritance).
- Renames: if member `m` declares package `P` under key `K`, the union's `P`
  entry is emitted under `K`. If `m` does not declare `P`, it is emitted under
  the canonical package name; on a name collision from a multi-version family,
  emit under `<name>_<major>` (any name works because `m`'s source does not
  reference it). Only **one key per `(package, version)`** is emitted — Cargo
  rejects the same package twice under different names (verified:
  `error: ... depends on crate serde ... multiple times with different names`).

### 4.6 Output

```nix
{
  members = [{ dir, name, polarity, internalDeps }];
  shards  = [{ key, label, members, memberDirs, sourceDirs, union }];
  memberShard = { "<dir>" = "<shard key>"; };
  canonical = { "<dir>" = <manifest attrset>; };   # merged with member manifest
}
```

Deterministic; exposed as `passthru.rustPlan` and `nix eval .#rustPlan`.

---

## 5. Emitter and patch mechanics (exact)

### 5.1 Generated manifests

Serialise with crane's own writer, which is already proven on `Cargo.toml`
(arrays of tables, nested dependency tables, `dep:` feature syntax):

```nix
unionManifest = pkgs.craneLib.writeTOML "Cargo.toml" plan.canonical.${dir};
```

`writeTOML` builds a derivation via `crane-json2toml`; it is referenced at
**build time only**, never read at eval time. No IFD.

### 5.2 Member source

Reuse the existing `mkCargoWorkspaceSource` (`pkg-helper.nix:102`) and extend
`cargoWorkspacePrePatch` (`pkg-helper.nix:235`) with an override map:

```nix
cargoWorkspacePrePatch = { projectDir, deps ? [], manifestOverrides ? {} }:
  joinLines [
    (concatStrings (mapAttrsToList (rel: drv: ''
      install -m u+w -D ${drv} ${rel}
    '') manifestOverrides))
    (existing awk that rewrites [workspace].members to [projectDir] ++ deps)
  ];
```

called from `mkRustDerivation` as

```nix
buildPrePatch = composeCargoWorkspacePrePatch {
  inherit projectDir;
  deps = resolvedDeps;
  manifestOverrides = { "${projectDir}/Cargo.toml" = unionManifest; };
  prePatch = userPrePatch;
};
```

`prePatch` runs before every cargo phase in `mkCargoDerivation`, so
`cargo build/test/clippy/fmt -p m` all see the same union manifest. The
generated manifest is a Nix input to the member derivation, so a change to the
union invalidates the member layer (intended) and only that layer plus its
dependents.

The source derivation is still named `cargo-workspace-source`, so the unpack
directory (`/build/cargo-workspace-source`, `CARGO_MANIFEST_DIR`) matches the
base. This is load-bearing for fingerprint reuse (verified fact 2).

### 5.3 Shard base

Generalise `mkSharedRustDepsBase` (`pkg-helper.nix:179`) and
`mkRustWorkspaceSource` (`pkg-helper.nix:167`) by a member set:

```nix
mkRustWorkspaceSourceFor = pkgs: { src, members }:
  mkWorkspaceSourcePath pkgs { inherit src; selectedDirs = members; };

mkSharedRustDepsBase = pkgs: { source, cargoLockContents, cargoVendorDir, members ? null }:
  craneLib.buildDepsOnly {
    dummySrc = craneLib.mkDummySrc { src = source; };
    pname = "abird-rust-workspace";
    version = "0.1.0";
    cargoExtraArgs = "--offline --workspace";     # source members were filtered to S
    inherit cargoLockContents cargoVendorDir;
  };
```

For shard `S`,
`source = mkRustWorkspaceSourceFor { inherit src; members = S.memberDirs; }`.
`mkWorkspaceSourcePath` already keeps the root
`Cargo.toml`/`Cargo.lock`/`.cargo` and filters to the selected directories, so
the base sees only `S`'s real manifests and `--workspace` resolves `U(S)`.

**Optional refinement (canonical base).** To make the base depend on `U(S)`
rather than the raw member manifest text, pass the generated manifests into
`mkDummySrc` through `extraDummyScript` (which runs after crane's manifest
cleaning and stubbing):

```nix
dummySrc = craneLib.mkDummySrc {
  src = shardSource;
  extraDummyScript = ''
    install -m u+w -D ${writeTOML "Cargo.toml" (canonical m)} $out/${m}/Cargo.toml
    …
  '';
};
```

This keeps crane's target/binary stubbing (so members with only `[[bin]]` are
handled) while canonicalising the dependency tables, and it makes the base
independent of `.rs` content and of manifest edits that do not change `U(S)`.
The dummy script must restore a build-script stub (`package.build`) for the base
so member build-dependencies are still primed; keep the value `mkDummySrc`
already wrote and only replace the dependency tables, or re-set it to a
`writeText "dummy.rs" "fn main() {}"` path. This refinement is optional; C1
works with the plain `--workspace` base over real manifests.

### 5.4 Member layer, packages, checks

`memberLayer`, `cargoArtifacts` selection, `dependencyArtifacts`,
`mkCargoArtifactsJoin`, `buildPackage`, and the three checks are **unchanged**
from `pkg-helper.nix:2383-2420`; only two inputs move:

- `buildSrc` now carries the canonical member manifest (via `prePatch`);
- `prefixNode` is `sharedDepsBase` for the member's shard.

```nix
prefixNode = if !workspaceMode then packageCargoArtifacts
             else shardBase.{shardOf projectDir};          # C1: one entry
memberLayer = craneLib.cargoBuild (craneCommonAttrs // {
  cargoArtifacts = dependencyArtifacts;                    # unchanged logic
  cargoExtraArgs = shellWords resolvedCraneBuildCargoArgs; # "--offline -p pname"
  doInstallCargoArtifacts = true;
});
```

No `-p` list is added for the member itself: the union is in its manifest, so
`-p m` already resolves the union.

---

## 6. Exactness, and where it degrades

### 6.1 Exact by construction within a shard

For every `m ∈ S`, the base resolves the closure of `U(S)` and the member
resolves the closure of `U(S)`. The root requirement table is identical, so the
fixpoint is identical. This is stronger than Plan B's "same signature" lemma: it
does not require `decls(m) = decls(S)`.

### 6.2 Feature widening is additive (and intentional)

Inside a shard, member `m` receives features requested by shard-mates. This is
additive widening. It is the same policy the repo already landed in
`[workspace.dependencies]` (clap `derive,env`; tokio eight features), which the
2026-09 review accepted as intentional (`rust-build-graph-review-2026-09.md`).
The base proves the widened set builds. REWEAVE-P guarantees no
`default-features` polarity is flipped; REWEAVE-1 may flip a polarity only if a
shard-mate enables defaults on a package another disables, and emits a warning
when it does.

### 6.3 Degradation paths (reachable vs not)

| construct                       | reachable? | treatment / degradation                                                                                                                                                          |
| ------------------------------- | ---------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| direct deps, `workspace = true` | yes        | merged; exact                                                                                                                                                                    |
| renamed deps (`package = "…"`)  | yes        | merged into the member's existing key; synthetic key only for a second version                                                                                                   |
| multi-version families          | yes        | one entry per version family; exact                                                                                                                                              |
| target-gated (`[target.<cfg>]`) | yes        | copied per `cfg`; same target ⇒ same activation                                                                                                                                  |
| build-deps / proc-macro / host  | yes        | separate domain; merged separately                                                                                                                                               |
| dev-deps                        | yes        | separate domain; merged separately                                                                                                                                               |
| optional external deps          | yes        | merged; `optional = AND`; if never activated in the base the member may build it extra (cache miss, not a correctness break)                                                     |
| member `[features]` tables      | partial    | preserved verbatim; if a feature activates an optional _external_ dep that the union must reproduce, the canonical `[features]` may need merging; unsupported ⇒ warn + fall back |
| `[patch]` / `[replace]`         | partial    | if identical across a shard they are kept once; if they conflict, shard them apart or fall back to L                                                                             |
| glob `[workspace].members`      | no         | `rustWorkspaceMembers` returns `[]`; whole repo falls back to L with a warning (unchanged from today)                                                                            |
| `projectDir = "."` root member  | no         | pre-existing L limitation; fall back                                                                                                                                             |
| transitive polarity conflict    | invisible  | build-time `cargo tree -e features` detector (§11); split shards on the affected package or warn                                                                                 |

### 6.4 The `default-features` BLOCKER, answered

Plan A's blocker is that one aggregate cannot represent "member X disables
defaults, member Y enables them". Plan C answers it structurally:

1. The rewrite is **per member**, not one aggregate.
2. REWEAVE-P's shard key includes the polarity vector, so no shard ever mixes
   opposite polarities for a package a member requests.
3. REWEAVE-1 is used only when the polarity vector is uniform (true in this
   repo: `reqwest` and `ssh-key` are `default-features = false` in the root
   table and no member re-enables them).
4. If a future member does conflict, the planner splits it into its own shard
   automatically (`shardKey` changes) rather than widening it silently.

So Plan C is **polarity-exact at the declaration level**, matching Plan B, while
still sharing bases across members with different feature sets.

---

## 7. Correctness argument

1. **The member's real source is unchanged.** Only the dependency table of its
   generated manifest differs; `[package]`/`[lib]`/`[[bin]]`/`[features]` and
   the real `src/` are preserved. The member still compiles its own code against
   its own targets.
2. **`U(S)` is a superset of every member's own declarations.** It is a merge
   that only adds features, ORs defaults, and copies entries. A missing
   activation manifests as a compile error in the member's real source — a loud
   failure, not silent mis-selection.
3. **Cargo is the resolver.** No evaluator-side closure, demand set, or semver
   matcher participates. The planner cannot produce an unsound graph; at worst
   it produces a union that is too small (compile error) or too large (extra
   cached compile).
4. **The base proves the union builds.** The shard base is `buildDepsOnly` over
   the same `U(S)`; if the union is unbuildable on the host, the base fails
   first, before any member.
5. **Polarity is preserved by construction** for REWEAVE-P; REWEAVE-1 warns on
   conflict.
6. **Failure detector.** Every member layer is a candidate for a build-time
   assertion that no external `Compiling` line appears (§11). This is the
   detector Plan A lacks.

Residual (acknowledged): a transitive polarity conflict or an
optional-activation the pure union cannot see. Both are bounded, detectable, and
degrade to a cache miss or a split shard, never to an unsound graph.

---

## 8. Fingerprint, lock, and vendor analysis

### 8.1 Fingerprint equality

Cargo's unit fingerprint for an external package depends on its own vendored
manifest, activated features (via `-C metadata`), profile, rustflags, the vendor
path, and `CARGO_MANIFEST_DIR` of the _unit_ (the vendor dir), not on the root
member's manifest text. Base and member therefore agree iff features, profile,
vendor path, and unpack path agree:

- **features**: equal by §6.1;
- **profile/rustflags**: shared `craneCommonAttrs`/stdenv;
- **vendor path**: one `vendorCargoDeps` derivation for the whole repo, derived
  from the unchanged lock (verified fact 2);
- **unpack path**: both sources are named `cargo-workspace-source`, so both
  unpack to `/build/cargo-workspace-source` (verified fact 2; `mkDummySrc`'s
  `sourceName` is basename-derived and this is why the name is load-bearing).

The member's own manifest changes its own crate hash (desired); it does not
enter any external unit's fingerprint. This was confirmed empirically: after
rewriting a member to the union, `cargo build --offline -p member` recompiled
**only `member`**, with all of `serde`, `serde_core`, `serde_derive`, `syn`,
`proc-macro2`, `quote`, `unicode-ident` reused from the `--workspace` base (§13,
spike 2).

### 8.2 Lock

- No new packages: the union is built only from declarations already present in
  the real member manifests, so every generated dependency is already in
  `Cargo.lock` and the vendor tree.
- Adding direct declarations changes the **member entries'** `dependencies`
  lists, which requires re-resolving. Verified:
  - `cargo build --locked -p member` fails with
    `cannot update the lock file … because --locked was passed`;
  - `cargo build --offline -p member` updates the lock **additively**: the only
    diff was one added edge (`"syn"` under the member's `dependencies`);
  - a **feature-only** change passes `--locked` with no lock diff.
- Therefore every crate build over a rewritten source runs with `--offline` (as
  L already does via `craneWorkspaceCargoArgs`, `pkg-helper.nix:37`), never
  `--locked`.
- To neutralise fact 3's "silent downgrade": generated entries for packages the
  member did not previously declare are pinned to the exact locked version
  (`=x.y.z`, read from `Cargo.lock`), and the added requirement is already
  satisfied by the lock, so Cargo has no reason to move any version. Validation
  V4 asserts the resolved versions are unchanged.

### 8.3 Vendor

`vendorCargoDeps` is computed from the same `cargoLockContents`, so it is the
same store path for the base, every shard, and every member. Plan C adds no
package and changes no version, so the vendor tree is byte-identical.

### 8.4 What Plan C does _not_ do

- It does not put a synthetic package in the lock (Plan A does).
- It does not run `cargo metadata`/`cargo fmt` on a lock-absent aggregate (Plan
  A's P1): the generated manifest references only locked packages, so the
  workspace is always lock-consistent after the `--offline` edge update.

---

## 9. Dev-dependencies and tests

- `buildDepsOnly` defaults `doCheck = true`, so the shard base runs
  `cargo test --offline --workspace --no-run` and primes dev-deps/test targets
  (crane `buildDepsOnly.nix`, verified).
- `canonicalManifest` includes the union of `[dev-dependencies]` for the shard,
  so `checks.test` (`cargoTest -p m`) and the deploy-time `buildPackage`
  `doCheck` resolve the same dev feature set as the base.
- `cargo build -p m` ignores dev-deps, so it reuses the base's normal units;
  `cargo test -p m` reuses the base's test units. The two domains are kept
  separate by construction.
- `[build-dependencies]` are merged as their own domain, so build-script units
  (host) match too.
- This also fixes review finding P2-e for the union path: the base primes test
  targets, so the deploy-time `cargo test` no longer recompiles them.

---

## 10. Platform gating and native inputs

- **Per-host shards.** The planner is manifest-only; the composition layer
  supplies the host-selected member list (from `meta.platforms`). A Darwin-only
  member never enters a Linux shard, closing review P1-A for the base.
- **Target tables are preserved** per `cfg`, so a `cfg(windows)` dependency of
  one member never activates on Linux and never contaminates the union.
- **Native-input seam.** The base takes an explicit
  `nativeBuildInputs`/`buildInputs` set (canonical per host), as Plan B
  recommends. Because the member now selects the shard union, it may need inputs
  that its own manifest did not declare; three options, in order:
  1. hoist the canonical set to the base and (optionally) the member layers;
  2. include a coarse native-input profile in the shard key so members with
     different input needs never share;
  3. give the base the union of its members' inputs (risks hash-consing). Start
     with (1)+(2). `*-sys` externals are already compiled in the base, so member
     layers usually need only link inputs, not build inputs.

---

## 11. Diagnostics, degradation, failure detector

- `passthru.rustPlan` on every package: shard key, shard members, `U(S)`, the
  canonical manifest, the packages added relative to the member's own closure,
  and the chosen mode (`REWEAVE-P`/`1`/`S`/`T`).
- A `rustPlan` flake output printing the partition and the dedup/churn decision,
  for `nix eval`.
- `lib.warn` (never throw) on every degrade: glob members, manifest parse
  failure, `[patch]` conflict, unsupported optional/feature activation, polarity
  conflict in REWEAVE-1, `craneLib == null`, non-workspace `projectDir`. Fall
  back to L's shared base for that member (or the whole repo), exactly as today.
- **Build-time failure detector (Plan C's differentiator).** A
  `checks.union-fresh` derivation builds the shard base, then runs the member
  layer with `cargo build --message-format=json -p m` and asserts no
  `compiler-artifact` with `fresh: false` whose package id is external (not a
  workspace member). Any external recompile means `U(S)` diverged from Cargo's
  resolution for that shard. This turns Plan B's V2 validation gate into a
  repo-native derivation that can run in `nix flake check`, which Plan A has no
  equivalent for. A `cargo tree -e features --offline` diff against the base can
  additionally surface transitive polarity conflicts.
- `cargo fmt`/`cargo metadata` are never run on a synthetic crate: they see real
  member manifests and a lock-consistent workspace.

---

## 12. Migration (staged, behind the L seams)

1. **C0 — planner diagnostic.** Add `lib/flake/rust-workspace.nix`, expose
   `rustPlan`, compute `U(M)` and the polarity vector; no build change. Compare
   `U(M)` with `cargo metadata` output from a scratch build.
2. **C1 — one union base + rewrite.** REWEAVE-1 (`shard = M`). Rewrite each
   member manifest to `U(M)`; point `prefixNode` at the existing
   `mkSharedRustDepsBase` over the full workspace. Verify zero external
   `Compiling` lines. This is a small, reversible change to existing seams.
3. **C2 — polarity shards.** Promote `shardKey` to the planner and parameterise
   `mkSharedRustDepsBase` by member set. Validate churn locality.
4. **C3 — optional canonical base.** Add the `extraDummyScript` manifest
   canonicalisation so the base no longer depends on raw manifest text.
5. **Fallback.** Keep L's base and per-member layers as the rollback path via a
   `useUnionRewrite = false` knob (default on for workspace members). The public
   `mkRustDerivation` contract is unchanged.

Seams kept stable: `src`/`dummySrc` injection, `cargoArtifacts` injection, a
shard label, and untouched `checks`/`pkgOps`/`devShell`/`passthru` wiring.

---

## 13. Validation and spike evidence

Standard gates, all with IFD disabled
(`nix eval --option allow-import-from-derivation false .#<pkg>.drvPath`):

- **V1 no IFD** — all packages evaluate; the planner reads only path sources.
- **V2 zero residual (headline)** — for each member, assert the member layer log
  has no `Compiling <external>`; cross-check `nix derivation show -r`.
- **V3 `.rs` locality** — append to a `.rs`; every shard base drv is unchanged
  and only the edited member's layer/package change.
- **V4 lock fidelity** — inside a rewritten build, `cargo metadata --offline`
  shows no version change for any used package; the lock diff is additive.
- **V5 polarity** — for `reqwest`/`ssh-key` members, `cargo tree -e features`
  shows defaults off and no default-only dependency.
- **V6 manifest churn locality** — edit one member `Cargo.toml`; only its shard
  base (C2) or the single base (C1) changes.
- **V7 fingerprint alignment** — base and member unpack to
  `/build/cargo-workspace-source`; one vendor dir.
- **V8 closure isolation** — `nix path-info -r` shows no artifact archive in
  deployed package closures (unchanged from L).
- **V9 eval tests** — partition deterministic; polarity shards disjoint and
  cover; equal polarity ⇒ may share; degrade-without-throw; join evaluates.
- **V10 correctness** — `nix flake check`, every package builds, isolated child
  flake unaffected.
- **V11 failure detector** — the zero-recompile assertion from §11 is green.

Spikes already run for this document (in `tmp/design-f/exp` and
`tmp/design-f/wsfeat`, cargo 1.95.0, vendored offline):

1. `[workspace.dependencies]` `default-features` semantics: member override wins
   (workspace `false` + member `true` ⇒ on; workspace `false` + member `false` ⇒
   off).
2. **Union forcing works**: base `cargo build --workspace` then a rewritten
   member `cargo build --offline -p member` recompiled only `member`; all
   externals (serde, serde_derive, syn, proc-macro2, quote, unicode-ident)
   reused. The un-rewritten member recompiled seven externals — the L residual.
3. **Lock**: adding a direct dependency on an already-locked transitive package
   fails `--locked` and, with `--offline`, produces a one-line additive lock
   change; a feature-only change passes `--locked` with no lock diff.
4. **Renames**: the same package under two names is rejected by Cargo, so the
   emitter merges into one key.
5. **Serialisation**: `crane-json2toml` round-trips `[[bin]]`, nested
   `[dependencies.x]`, `dep:` features, and workspace-inherited package fields —
   the writer crane already uses for `mkDummySrc`.

---

## 14. Honest comparison

### 14.1 vs Plan A (F-union, synthetic aggregate)

| dimension                   | Plan A                                       | Plan C (REWEAVE)                                |
| --------------------------- | -------------------------------------------- | ----------------------------------------------- |
| union mechanism             | `-p m -p crane-union`                        | rewrite `m`'s manifest to the union             |
| synthetic workspace member  | yes (lock entry, new package)                | **no**                                          |
| `default-features` polarity | one aggregate cannot represent it (blocker)  | per-member rewrite + polarity shards; preserved |
| `cargo fmt`/`metadata`      | runs on a lock-absent source                 | real, lock-consistent manifests                 |
| lock handling               | adds a synthetic package; re-resolution risk | additive edge only; no new package              |
| churn locality              | global base                                  | one shard (C1) or polarity shards (C2)          |
| failure detector            | none                                         | zero-external-recompile assertion               |
| dedup                       | one union base                               | one union base (same)                           |

Plan C beats Plan A on every point except that Plan A's planner is a single
fixed union, while Plan C's is a small merge function. Plan C keeps Plan A's
dedup ceiling and removes its failure modes.

### 14.2 vs Plan B (F-cluster, per-signature real selections)

| dimension                      | Plan B                                       | Plan C (REWEAVE)                                                            |
| ------------------------------ | -------------------------------------------- | --------------------------------------------------------------------------- |
| base ↔ member agreement        | requires equal **full signature**            | guaranteed by rewriting `m` to the base union                               |
| sharing when signatures differ | singleton (B0) or chained with residual (B1) | shares; rewrite absorbs the difference                                      |
| external compiles @5           | ≈ 753 (B0) or ≈ L (B1, residual)             | **367 (union), 0 residual**                                                 |
| external compiles @24          | ≈ U + divergences (B1)                       | ≈ U (C1), or per-shard U (C2)                                               |
| `default-features` exactness   | exact (real manifests only)                  | exact at declaration level (polarity shards); transitive conflicts detected |
| manifest synthesis             | none                                         | real member manifests, canonical dependency tables                          |
| correctness dependency         | grouping is advisory only                    | rewrite must be a superset; errors are loud                                 |
| churn locality                 | per-cluster / spine                          | per-shard (C2)                                                              |

Plan B is the **exactness-first** endpoint; Plan C is the **dedup-first**
endpoint. They are the same mechanism at different shard keys: Plan B is
REWEAVE-S (shard = full signature, rewrite is a no-op) and Plan A is REWEAVE-1
with a stub instead of a rewrite. Plan C's contribution is the middle: rewrite
makes a shard larger than a signature class safe, so the repo can have one base
and zero residual at once.

### 14.3 vs landed Design L

| dimension                   | L                | Plan C                                                              |
| --------------------------- | ---------------- | ------------------------------------------------------------------- |
| residual (syn, clap, sha2)  | yes              | no                                                                  |
| external compiles           | union + residual | union                                                               |
| `.rs` locality              | yes              | yes                                                                 |
| dep-manifest churn          | global base      | global (C1) or per shard (C2)                                       |
| member manifest             | real             | real + canonical dependency tables                                  |
| complexity                  | low              | low–medium: a merge function + one `prePatch` override              |
| correctness regression risk | none             | low; loud on under-approximation, base-proven on over-approximation |

Plan C is a strict refinement of L: same structure, same fallback, same public
API, with the residual removed by making the member's declaration table equal to
the base's.

### 14.4 When to choose which

- **Plan A** when raw cold-compile dedup dominates and there is no
  `default-features` polarity conflict, no `fmt`/`metadata` constraint, and no
  churn-locality need.
- **Plan B** when exact, untouched manifests matter more than sharing, or when
  the member set genuinely clusters by signature.
- **Plan C** when the repo shares a lot (this one), polarity is uniform or
  shardable, and the goal is "one base, zero residual" — the stated goal of
  Design F.

---

## 15. Open questions and residual risks

- **Canonical base cost.** The optional `extraDummyScript` canonicalisation
  needs care with build-script stubs; C1 works without it. Decide after C1
  measurements.
- **Transitive polarity conflicts** are invisible to pure eval. The build-time
  `cargo tree -e features` detector is the mitigation; if a real conflict
  appears, move the affected package into the shard key.
- **Optional/feature-activated externals** are the main fidelity gap. If the
  repo starts using member `[features]` to gate external deps, either merge the
  feature tables or switch those members to REWEAVE-S.
- **Native inputs** may need hoisting to the base; per-member profiles in the
  shard key are the fallback.
- **Shard-key default.** REWEAVE-P vs REWEAVE-1: start with P, which collapses
  to one shard here and never widens polarity.
- **`mkTrunkProject`/`mkCraneRustPackage`** are not routed through the planner
  in this plan; they keep their current paths.

---

## References

- `.agents/docs/plans/design-f-build-graph-2026-09.md` — Design F draft,
  union-forcing options, Plan A description and critique.
- `.agents/docs/plans/rust-workspace-build-graph-2026-09.md` — L/F handoff,
  dependency model, L properties, seam list.
- `.agents/docs/plans/design-l-implementation-2026-09.md` — landed L mechanics.
- `.agents/docs/notes/tooling/rust-build-graph-review-2026-09.md` — P1-A/P1-B,
  P2-e, `.rs`-stability caveat, feature-normalization evidence.
- `tmp/design-f/plan-b.md` — Plan B (F-cluster), the exactness-first endpoint
  and the shard-key continuum this plan builds on.
- `lib/flake/pkg-helper.nix` — `mkWorkspaceSourcePath` (67),
  `mkCargoWorkspaceSource` (102), `rustWorkspaceMembers` (142),
  `mkRustWorkspaceSource` (167), `mkSharedRustDepsBase` (179),
  `mkCargoArtifactsJoin` (198), `cargoWorkspacePrePatch` (235),
  `mkRustDerivation` workspace mode (2235), `sharedDepsBase` (2348),
  `memberLayer` (2400).
- Crane source rev `73b9805`: `lib/buildDepsOnly.nix` (`cargoArtifacts = null`,
  `doCheck = true`, three phases), `lib/mkDummySrc.nix` (`sourceName`,
  `extraDummyScript`), `lib/filters/cargoTomlConservative.nix`,
  `lib/writeTOMLViaCraneUtils.nix`.
- Spike artifacts: `tmp/design-f/exp` (union forcing, lock, renames),
  `tmp/design-f/wsfeat` (workspace inheritance semantics).
