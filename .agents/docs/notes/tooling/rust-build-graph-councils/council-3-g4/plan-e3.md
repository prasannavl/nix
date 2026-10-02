# E3 — RESOLUTION-CLASS NODES (`CLASSNODE`)

Status: engineering plan for council G4 (candidate E3), implementation-ready
except for the explicitly labelled spikes. Supersedes nothing; adopts the
verified mechanics of `tmp/design-g4/research.md` and
`tmp/design-g4/explore.md`, and the landed seams of Design L
(`lib/flake/pkg-helper.nix`) and Design M
(`.agents/docs/plans/dual-mode-rust-build-graph-2026-09.md`).

Read-only repo except `tmp/design-g4/`. All new analysis artifacts:
`tmp/design-g4/analyze_nodes.py`, plus the vendor-fingerprint spike recorded in
§1.2 and §14 (R4).

---

## 0. Decision (one paragraph)

Replace the single `--workspace` crane base with a **minimal set of
resolution-class base nodes**: one synthetic deps-workspace per distinct
_effective external declaration map_, each keyed purely on that map (+ profile /
host / toolchain), with its own pruned lock and pruned vendor. A member's
`memberLayer` inherits exactly its class node, so `cargo build -p m` resolves
its own externals and reuses them, with **no widening**. Equality classes
(hash-consing identical maps into one drv) and, in an opt-in "fused" scope, a
small meet-lattice (`F ⊆ M` byte-identically) reduce compiles further. G4
locality is delivered in `local` mode because every node's derivation is a pure
function of the map: a member manifest edit that changes member `m`'s map moves
`m` to a (new or existing) node and leaves every other class node
byte-identical; only `m` and its dependents rebuild. The one hard physical
constraint found is that **cargo fingerprints the vendored source root**, so
cross-class artifact inheritance requires a shared vendor derivation and
therefore trades sibling-locality for dedup; that trade is exposed as an
explicit `scope` knob, defaulting to G4-exact `local`.

---

## 1. Problem and the two facts that shape the design

### 1.1 Restatement

Today (`pkg-helper.nix:179-196`, `:2348-2363`, `:2400-2411`): one
`mkSharedRustDepsBase` whose dummy source is every member manifest and whose
`cargoExtraArgs = "--offline --workspace"`. `buildDepsOnly` hard-sets
`cargoArtifacts = null` (`crane lib/buildDepsOnly.nix:64`), so any manifest byte
change rebuilds all externals and re-runs all five member layers. Target:

- a member-manifest edit invalidates only that member's own external closure and
  its dependents;
- root `[workspace.dependencies]` and shared-`Cargo.lock` edits may be global;
- minimise total compiles and node count at 24 members;
- no IFD; preserve G10/G11; simple API; mirror-compatible; L rollback.

### 1.2 Fact A — cargo fingerprints the vendored source _root_

Measured with the verified `stub-agent` workspace
(`tmp/design-g4/vendor-agent/`, 64 vendored crates, 28 compile units):

| sequence                                                                                                           | result            |
| ------------------------------------------------------------------------------------------------------------------ | ----------------- |
| build against `vendordir`, then rebuild against `vendordirB` (byte-identical dir, different path)                  | **28 recompiles** |
| build against `vendordir`, then against a `vendordirD` whose entries are **symlinks to the exact same crate dirs** | **28 recompiles** |
| rebuild against the _same_ root                                                                                    | 0 recompiles      |

Cause: a cargo `directory` source's `SourceId` embeds the absolute vendor path,
so every vendored package id (and therefore every fingerprint and `-C metadata`)
changes when the root changes. **Consequence:** artifact inheritance across two
derivations is real only if they use the _identical_ `cargoVendorDir` derivation
store path. This is the single most important constraint on the node DAG, and it
is why the default mode is per-class and the chaining mode is scoped.

### 1.3 Fact B — `agent ⊆ manager` is false at the declaration-map level

The research note lists `agent ⊆ manager` as chain-savable. That is true for the
resolved **package closure** (65 ⊆ 233) but **false for the resolved direct
declaration map** (the sound pure-eval sharing key):

- `agent` externals: `anyhow, clap, libc, serde, serde_json, shlex` (+ dev
  `tempfile`).
- `manager` externals:
  `age, anyhow, base64, clap, humantime, libc, serde,
  serde_json, sha2, ssh-key, tempfile, uuid, zeroize`.
- `shlex` is in `agent` and not in `manager`; `tempfile` differs by dependency
  domain (`dev` in agent, `normal` in manager).

Every pair in the repo was checked (`analyze_nodes.py`): **there are zero strict
declaration-map subset relations at 5 members.** The useful structure is the
_meet_ (byte-identical intersection): `{anyhow, clap, serde}` (all four),
`{anyhow, clap, libc, serde, serde_json, tempfile}` for agent/manager (closure
64), and the 9-entry `nats-*` async stack (closure 188). The design therefore
treats **meets**, not chains, as the dedup primitive, and still supports strict
subset edges where they exist in other repos.

---

## 2. The key: the effective external declaration map

All of this is computed in pure eval from evaluator-visible paths
(`builtins.readFile` / `fromTOML` / `readDir` / `pathExists`); no IFD.

### 2.1 Per-member declaration map

For member `m`, walk `[dependencies]`, `[build-dependencies]`,
`[dev-dependencies]` and every `[target.<cfg>.*]` variant, for each of which the
entry key is `(domain, target, package)` with `domain ∈ {normal, build, dev}`,
`target = "."` or the literal cfg string, and `package` = the declared key
(respecting `package = "..."` renames). Resolve Cargo workspace inheritance
exactly (Design F `resolveDep`, verified semantics): `workspace = true` merges
`[workspace.dependencies].<key>` under the member's overrides for `features` /
`default-features` / `optional`.

Entry value (canonical, sorted):

```nix
{ version            # requirement string (NOT resolved to a lock version)
; features           # sorted unique list
; default-features   # bool
; optional           # bool
; path               # null for externals; the literal path for in-repo deps
}
```

### 2.2 Effective map (closure over in-repo path deps)

```nix
E(m)  = { (domain,target,package) -> entry | entry.path == null }   # own externals
Eff(m) = E(m) ∪ ⋃_{d ∈ internalDeps*(m)} E(d)
```

`Eff(m)` is the union of the member's own externals with the externals of every
transitive in-repo path dependency. It is exactly the set of external units the
real `cargo build -p m` will need (the path deps themselves are compiled from
source in the member layer). Conflict policy (degrade, never widen): if the same
`(domain,target,package)` appears with two different byte-identical-intent
values across the union (e.g. two version families), the member is marked
`degrade = "local"` and uses its own node; `lib.warn` is emitted.

### 2.3 The sharing key

```nix
classKey(m) = hashString "sha256" (toJSON {
  map      = Eff(m);                 # canonical, sorted
  resolver = root.workspace.resolver;
  profile  = nativeProfile(m);       # build/native inputs the base needs
  host     = hostPlatform.system;
  toolchain = rustcVersion;          # from the pinned toolchain, eval-visible
})
```

`classKey` is the pure-eval proxy for "inputs byte-identical" (research §4):
sound (identical maps + lock + profile + toolchain ⇒ identical resolution) but
not complete. The **root `Cargo.lock` is not in the key**; instead each node
carries its pruned _lock slice_, so a lock edit only changes nodes whose slice
changed (see §4.2 and §8). `Eff` intentionally excludes `[features]`-driven
activation: any member whose `[features]` table contains `dep:<external>` or
`<external>/<feat>` is `activationSensitive` and is forced into its own node
(`solo`), because pure eval cannot evaluate feature activation.

### 2.4 Equality classes and scopes

```nix
classes = groupBy classKey members          # equality classes (free dedup)
```

Scopes are the unit of **vendor sharing** (and therefore of artifact chaining):

| `scope` mode         | group                     | locality of a member manifest edit                                                                         | use                             |
| -------------------- | ------------------------- | ---------------------------------------------------------------------------------------------------------- | ------------------------------- |
| `local` (default)    | one class per scope       | only `m` + dependents; G4-exact                                                                            | required by G4                  |
| `pathComponents`     | path-connected components | component-granular; dependency edits already rebuild dependents, dependent edits also rebuild dependencies | opt-in                          |
| `fused` / `clusters` | explicit `{a,b}` clusters | cluster-granular                                                                                           | maximum dedup                   |
| `global`             | whole repo                | global                                                                                                     | diagnostics only, never default |

In `local` mode each class gets its own pruned lock + vendor, so the node key is
exactly the map slice and Fact A does not bite (nothing needs to chain).

---

## 3. Node computation (pure eval)

Module: **new** `lib/flake/rust-resolution.nix` (pure; no `pkgs`, no crane).
Inputs: repo path, host string, `nativeProfileOf` (or a per-member attrset), a
`scope` knob. Output: a deterministic `plan` attrset.

Algorithm:

1. `members` ← root `[workspace].members` (globs via `readDir` + `match`; a
   non-expandable glob degrades all affected members to L, `lib.warn`).
2. For each member: parse manifest, resolve inheritance, compute `E`, `Eff`,
   `activationSensitive`, `degrade`, `internalDeps` (path edges).
3. `classes` ← `groupBy classKey`.
4. For each scope: a. `scopeMap` = canonical union of its classes' `Eff` maps.
   b. `scopeLock` = prune the root lock to the reachable closure of `scopeMap`
   (plus the in-repo path packages in the scope), §4.2. c. **Meet lattice**
   (skipped in `local`, and skipped when a scope has one class): compute all
   pairwise byte-identical meets `M ∩ N` where an entry is kept only if its
   canonical value is equal in both; then greedily add meets by estimated saving
   `(|closure(M)| × (participants − 1))` while the meet adds at least one entry
   not already in a chosen ancestor, capped at `O(n²)` candidate pairs and a max
   depth of 3. Meets that are not a byte-identical subset of every participant
   are discarded. d. Attach each class node to its largest chosen foundation
   node whose map is a subset of `Eff(m)` (ties broken by map hash).
5. Canonicalise every list (sorted, unique) so hash-consing is stable.

Plan shape (observable as `passthru.rustResolution` and
`flake.rustResolutionPlan`):

```nix
{
  version = "1";
  members = [ { dir; name; classKey; eff; effHash; activationSensitive;
                degrade; profile; scope; } ];
  nodes   = [ { key; kind = "class"|"foundation"; map; mapHash; parent?;
                scope; vendor; prunedLock; closureSize; members = [dir...]; } ];
  edges   = [ { from; to; } ];           # from is a subset parent of to
  warnings = [ "..." ];
}
```

**Complexity budget:** ≤ 380 lines. If it exceeds ~450, stop and drop the meet
lattice to equality classes only (still G4-correct).

---

## 4. Per-node source, lock and vendor

### 4.1 Stub deps-workspace source

For a node with map `K` (a class `Eff` or a foundation meet), generate:

```text
<node>/Cargo.toml              [workspace] resolver = <root resolver>; members = ["stub"]
<node>/stub/Cargo.toml         [package] name = "rcn-stub-<mapHash8>" version="0.0.0" edition=<root>
                               [lib] path = "src/lib.rs"
                               [dependencies]  <K normal "." concrete entries>
                               [build-dependencies] <K build "." entries>
                               [dev-dependencies]   <K dev "." entries>
                               [target.<cfg>.dependencies] <K normal cfg entries> (per cfg)
<node>/stub/src/lib.rs         empty
```

Entries are **concrete** (no `workspace = true`); `version`/`features`/
`default-features`/`optional` verbatim from the canonical map; `optional = true`
entries are only permitted when the node is a `solo` activation node. The
`pname` is `abird-rust-class-<mapHash8>` (or `...-found-<hash8>`), so identical
maps hash-cons to one derivation. The source basename is **not**
`cargo-workspace-source` (this is a deps-only build; the crate-name/dummy
invariants still hold because `mkDummySrc` is given this tree directly).

### 4.2 Pruned lock (pure)

`prune_lock.py` generalised to Nix:

- parse the root `Cargo.lock` (`fromTOML`);
- index registry packages by name and resolve each `dependencies` entry by
  `name version` where present, else the single same-name package;
- BFS from the node's `K` roots (resolved to locked instances by the entry's
  requirement, choosing the unique matching version; ambiguous ⇒ degrade);
- keep in-repo path packages of the scope (no `source`), with their edges;
- emit a lock with the same `version` header, sorted `[[package]]` entries,
  original `checksum`/`source` bytes. Over-approximation is dropped; no version
  is ever changed. This is `--offline`-safe, **not** `--locked`-safe (research
  §2), and the vendor, not `--locked`, is the version pin.

### 4.3 Pruned vendor

```nix
node.vendor = craneLib.vendorCargoDeps { cargoLockContents = node.prunedLock; };
```

`crane` builds per-crate `downloadCargoPackage` FODs and links them into one
`vendor-cargo-deps` dir. Two nodes with identical maps and identical lock slices
produce identical `prunedLock` text and therefore identical vendor/store paths.

### 4.4 Source lock isolation (required for lock/`G4` locality)

`mkWorkspaceSourcePath` (`pkg-helper.nix:67`) currently always keeps
`Cargo.lock`, so any lock edit enters every member source. Add
`lockMode = "omit" | "keep"` (default `keep`); in the resolution path use
`omit`. The member/base derivations pass `cargoLockContents = node.prunedLock`
and `cargoVendorDir = node.vendor`; crane's `replaceCargoLockHook` recreates
`Cargo.lock` in the unpacked tree
(`crane lib/setupHooks/replaceCargoLockHook.sh`). Without this, adding one
dependency to one member changes the shared lock and invalidates every member
source; with it, only the affected node slices change. This is the difference
between G4 satisfied and G4 defeated on the most common edit (adding a dep).

---

## 5. Node DAG and chaining rules

Node kinds:

- **class node** `C(m)`: stub deps-workspace with map `Eff(m)`; parent = the
  chosen foundation node or `null`.
- **foundation node** `F(M)`: stub deps-workspace with meet map `M`; parent = a
  smaller chosen foundation node or `null`.
- **member layer** `L(m)`: real per-member source (`mkCargoWorkspaceSource`,
  `prePatch = cargoWorkspacePrePatch`), `cargoArtifacts = C(m)` (or a
  dependent's `L(d)` only when `d` is an in-repo dependency and the scope is
  fused/shared), runs `cargo build -p m` and publishes `target.tar.zst`.
- **package** `P(m)`: `buildPackage` inheriting `L(m)`, no exported artifacts.

Edge rule (the only sound one):

> `A → B` is allowed **iff** `map(A)` is a byte-identical subset of `map(B)`
> **and** `vendor(A) == vendor(B)` (identical store path, Fact A).

In `local` mode no two scopes share a vendor, so the only edges are within a
scope; a class with ≥2 members is a single node (hash-consed), and a singleton
class has no parent. In `fused`/`pathComponents` mode, the scope's single vendor
is shared by all its class and foundation nodes, so meets and subset chains are
buildable. Chaining is realised by `cargoArtifacts = parent` (crane's `.prev`
delta archive): the parent archives its compiled units and the child compiles
only the delta.

Exactness is preserved in every mode because the child's stub still declares its
**full** map; the parent is a cache, never a resolution input.

---

## 6. Exact cargo invocations

Class / foundation node (replaces `buildDepsOnly` so it can inherit):

```nix
craneLib.mkCargoDerivation {
  pname = "abird-rust-class-${mapHash8}";
  version = "0.1.0";
  src = stubSource;                  # §4.1
  prePatch = "";                     # generated tree is already exactly K
  cargoArtifacts = parentNode;       # null for a root node
  cargoVendorDir = node.vendor;
  cargoLockContents = node.prunedLock;
  CARGO_NET_OFFLINE = "true";
  doInstallCargoArtifacts = true;
  buildPhaseCargoCommand = ''
    cargo check --offline --all-targets
    cargo build --offline
  '';
  checkPhaseCargoCommand = "cargo test --offline --no-run";
  doCheck = true;
}
```

Member layer:

```nix
craneLib.cargoBuild (craneCommonAttrs // {
  src = buildSrc;                    # real per-member tree, lockMode = omit
  prePatch = composeCargoWorkspacePrePatch { projectDir; deps = resolvedDeps; };
  cargoArtifacts = classNode(m);     # or the in-repo dependency's memberLayer (fused)
  cargoVendorDir = classNode(m).vendor;
  cargoLockContents = classNode(m).prunedLock;
  cargoExtraArgs = "--offline -p ${pname}";
  doInstallCargoArtifacts = true;
  CARGO_NET_OFFLINE = "true";
});
```

`--workspace` is gone; `--locked` is gone (research §2). `--offline` plus the
pruned vendor is the version pin. Checks keep their existing shape (`cargoFmt`;
`cargoClippy --offline -p m`; `cargoTest --offline -p m`) and inherit `L(m)`.

---

## 7. Exactness proof and non-sharing conditions

**Claim (no widening).** For every member `m`, `C(m)`'s stub declares exactly
`Eff(m)`, and `L(m)`'s real manifests declare the same external entries with the
same canonical values (by construction of `Eff` from those manifests plus the
transitive in-repo deps' own manifests). Cargo feature unification is a function
of the root requirement table, the vendored package sources, the profile and the
toolchain. `C(m)` and `L(m)` use the same vendor, lock slice, profile and
toolchain; therefore every external unit `L(m)` needs is either already present
in `C(m)` with an identical fingerprint (inherited via `.prev`) or is a delta
crate. `-p m` selects exactly `m`; the parent archives cannot add a member to
the selection. Hence the deployed artifact is a function of `m`'s own resolved
requirements, never of a peer's.

**Soundness of the pure-eval test.** If two members have equal `classKey`, their
manifest-derived external requirement tables (after workspace resolution) are
byte-identical; with the same lock/profile/toolchain their cargo resolutions and
unit fingerprints are identical, so sharing cannot widen. The converse is not
claimed: unequal maps may still resolve identically (they just pay a duplicate
node).

**Meets.** `F(M)` is built only from entries whose canonical values are
byte-identical in every participant; therefore `map(F) ⊆ map(Eff(m))` for each
participant `m` and Fact A's vendor equality holds inside a scope. The meet is a
cache prefix, not a resolution change.

**Two members must not share (must be separate nodes) if any of:**

1. `Eff` differs in any `(domain,target,package)` entry (version req, features,
   `default-features`, `optional`);
2. `activationSensitive` (an external is referenced from `[features]`);
3. different `nativeProfile` (build/check native inputs), host, or toolchain;
4. `[patch]`/`[replace]` present (not representable in pure eval);
5. a version-family conflict inside a candidate meet/class;
6. `degrade = "local"` from any parse/glob/ambiguity failure.

---

## 8. Invalidation matrix

| edit                                                                        | `local` (default, G4-exact)                                                                                                                           | `fused`/`pathComponents`                                                     |
| --------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| member `m` `[dependencies]` **semantic** change (map changes)               | new class node for `m`; old class node retained byte-identical for its other members; `L(m)` + `P(m)` + dependents; **no other class node or member** | scope vendor/lock changes ⇒ all nodes in that scope; other scopes unaffected |
| member `m` non-semantic manifest edit (`description`, `license`, `[lints]`) | nothing (crane already launders; and the node keys only on the map)                                                                                   | nothing                                                                      |
| member `m` `.rs` content                                                    | `buildSrc(m)` + `L(m)` + `P(m)` + dependents; all nodes byte-stable                                                                                   | same                                                                         |
| member `m` `.rs` add/remove (`lib.rs`/`main.rs`/`bin/*`)                    | `L(m)` + dependents; node stability expected, spike R3 confirms the `mkDummySrc` caveat                                                               | same                                                                         |
| in-repo dep `d` manifest change                                             | `d`'s class node + `d` + every `m` with `d ∈ internalDeps*`; unrelated classes untouched                                                              | same within the component                                                    |
| root `[workspace.dependencies]` change                                      | every member that inherits the changed key changes class ⇒ those nodes + dependents (allowed global in spirit; often fewer than all)                  | all scopes                                                                   |
| `Cargo.lock` version bump inside closure of class `k`                       | only `k`'s pruned lock/vendor change ⇒ node `k` + its members + dependents; **other classes unaffected** (with §4.4)                                  | the scope's lock/vendor change ⇒ scope                                       |
| `Cargo.lock` change outside every closure (e.g. new member's deps)          | nothing (root lock excluded from sources)                                                                                                             | nothing                                                                      |
| new member                                                                  | new class node + root manifest change                                                                                                                 | new class node                                                               |
| toolchain/profile/host change                                               | every class (all keys change)                                                                                                                         | all scopes                                                                   |
| internal `internalDeps`/path edge change                                    | `m`'s class node, `m` + dependents                                                                                                                    | component                                                                    |

The `local` column is exactly the G4 contract: a member manifest edit touches
only that member's node(s) and its dependents.

---

## 9. Cost model

Verified 5-member closures (research §5):
`hello-rust 0, agent 65, wrecking 216,
manager 233, bridge 239`; union **367**;
per-member sum **753** (2.052×). Direct-declaration signatures: **5 distinct**
(`analyze_nodes.py`) — zero equality dedup at 5. Strict subset relations: **0**
(Fact B). Domain-insensitive meets: agent/manager closure **64** (6 entries
incl. `tempfile`), `nats-*` closure **188** (9 entries), global
`{anyhow,clap,serde}` closure **25**.

### 9.1 Five members

| mode                   | base nodes             | total external compiles | factor vs union | locality              |
| ---------------------- | ---------------------- | ----------------------- | --------------- | --------------------- |
| L today                | 1                      | 367                     | 1.00×           | **global** (fails G4) |
| `local` (default)      | 4 (class)              | 753                     | 2.05×           | **exact, G4**         |
| `pathComponents`       | 4 class + 1 foundation | ~234 + 239 + 216 = 689  | 1.88×           | component             |
| `fused` (2 ecosystems) | 4 class + 2 foundation | **~501**                | **1.37×**       | scope                 |
| `global` fused         | 4 class + 3 foundation | ~480                    | 1.31×           | global                |

Fused arithmetic: `{agent,manager}` = 64 + (65−64) + (233−64) = 234;
`{bridge,wrecking}` = 188 + (239−188) + (216−188) = 267; total 501. (`local`
compiles are unchanged from per-member because there are no equal signatures;
its win is locality plus future dedup.)

### 9.2 Twenty-four members — model and uncertainty

The metric is `Σ over distinct classes |closure(class)| / |union|`, not member
count. Let `E` be the mean class closure and `U` the ecosystem union. Scenarios
(anchor `E ≈ 188`, `U = 367` at 5; `U` grows with ecosystems):

| scenario                                      | distinct classes | mean closure | union | `local` cost | factor | base nodes |
| --------------------------------------------- | ---------------- | ------------ | ----- | ------------ | ------ | ---------- |
| S-A equality-heavy (24 members, 4 signatures) | 4                | 188          | 367   | 753          | 2.05×  | 4          |
| S-B mixed (12 signatures, 4–6 ecosystems)     | 12               | 188          | 500   | 2256         | 4.5×   | 12         |
| S-C divergent (24 signatures, 6 ecosystems)   | 24               | 188          | 600   | 4512         | 7.5×   | 24         |
| S-B fused                                     | 12               | 188          | 500   | ~1500        | ~3.0×  | ~18        |
| S-C fused                                     | 24               | 188          | 600   | ~3000        | ~5.0×  | ~40        |

Reading: `local` cost scales with **class count**, so the 24-member curve is
dominated by how many _distinct_ maps the 24 members have (a function of the
repo, not of `CLASSNODE`). Equality classes are the main lever and they are
free; meets/chains are the second lever and they cost scope locality. The
research's 3–6× projection corresponds to S-B/S-C. **Uncertainty:** `E`, `U` and
the signature distribution are projected, not measured; the real curve must be
recomputed from the 24 manifests by `analyze_nodes.py` before enabling any
`fused` default (spike R8). Node count in `local` = number of distinct non-empty
classes (≤ members); `fused` adds one node per chosen meet.

### 9.3 Node-count minimisation

`local` minimises node count (one per class; equality classes collapse). Meets
reduce compiles but add nodes; the greedy cap in §3c bounds the extra nodes at
`O(depth × clusters)`. Default is `local`; `fused` is per-cluster opt-in so an
operator can buy compiles with locality knowingly.

---

## 10. G10 / G11 interaction

- **Pure function of the member.** In `local` mode every node's source, lock
  slice, vendor and `pname` are functions of the member's own (layout-stable)
  manifest map plus the shared root/resolver. A layout-preserving generated
  mirror (Design M §6) therefore produces the **same** class node drv, so
  `standalone == composed == in-repo` holds by `drvPath` equality, not just
  semantically. This is a stronger G10 property than L's global union base.
- **Injection seam.** Follow Design M: add `base ? null` to `mkRustDerivation`,
  `prefixNode = if base != null then base else sharedDepsBase`, and thread it
  through `packages.nix`/`root.nix`/`default.nix` together with
  `externalPackagesFor`/`pkgHelper`. A mirror's
  `lib.<system>.mkPackage
  { pkgs; base; pkgHelper }` passes its own class
  node; the monorepo passes the same map-derived node. Composition never calls a
  member-specific base factory (the E1 P1-2/P1-3 rule).
- **`fused` is not mirror-compatible.** A scope vendor depends on the scope's
  peer union, so a standalone member cannot reproduce it. `fused` is a monorepo
  optimisation only; mirrors always use `local`. State this in the plan output
  (`node.scope`, `mirrorCompatible = scope == "local"`).
- **`basePolicy`.** `local` (new default candidate), `union` (L, zero-regression
  rollout), `legacy` (per-package rollback). Rollout flips node-by-node.
- G11 replacement (`externalPackagesFor`) and the passthru contract
  (`memberLayer`, `projectDir`, `depsBase`, `rustResolution`, `mirrorUnit`) are
  unchanged from Design M §7.

## 11. Integration, checks, internal deps, platform gating, rollback

- **Seam:** `mkSharedRustDepsBase` stays as the L fallback; add
  `mkResolutionDepsBase { map; parent; scope; profile; cargoLockContents;
  cargoVendorDir; }`
  next to it, and `mkWorkspaceSourcePath` gains `lockMode = "omit"` (§4.4).
  `mkRustDerivation` gains `base ? null`, `baseLabel ? null`,
  `resolution ? null`; add all three to the existing `removeAttrs` list (fixes
  the E1 P2-8 class of bug). Defaults reproduce L bit-for-bit.
- **Internal path deps:** `resolvedDeps`/`buildPrePatch`/`internalDeps` keep
  their landed semantics. In `local` mode `L(m)`'s `cargoArtifacts` is `C(m)`;
  an in-repo dependency's crate is compiled inside `L(m)` from its real source.
  Reusing the dependency's `memberLayer` is only valid in a shared-vendor scope.
- **Checks:** `checks.fmt` unchanged; `checks.lint`/`checks.test` inherit `L(m)`
  and pass the node's `cargoVendorDir`/`cargoLockContents`; a new
  `checks.resolution-fresh-<pname>` asserts zero external `Compiling` lines in
  `L(m)` beyond its declared delta (the Design F freshness gate, generalised).
- **Platform gating:** `classKey` includes host; `[target.<cfg>.*]` entries are
  part of the map with the cfg string; host-unavailable members are filtered by
  the composition before scopes are formed.
- **Diagnostics:** `passthru.rustResolution` on every package (`classKey`,
  `map`, `parent`, `scope`, `vendor`, `closureSize`, `degrade`);
  `flake.rustResolutionPlan` prints classes, meets, predicted compile counts and
  the chosen scope for `nix eval`.
- **Degradation:** `lib.warn`, never throw. Any failure degrades the affected
  member to `resolution = null` ⇒ L's `sharedDepsBase` (or
  `useWorkspaceDeps =
  false` for the legacy per-package path). A root-manifest
  failure degrades the whole repo to L exactly as today.
- **Rollback:** `resolutionMode = "l"` sets `base = null` everywhere and
  reproduces landed L drv paths; `useWorkspaceDeps = false` is the per-member
  legacy escape.

## 12. Diagnostics and degradation triggers

`lib.warn` on: unexpandable glob; manifest parse failure; `[patch]`/`[replace]`;
git or alternate-registry deps; `activationSensitive`; ambiguous lock slice;
version-family conflict in a class/meet; `[features]` external activation;
`craneLib == null`; non-member `projectDir`; `scope = "fused"` with a
`mirrorCompatible = false` warning; a node whose `closureSize` exceeds a
configurable budget (default 400) with a suggestion to use `local`.

## 13. Staged migration

| stage    | change                                                                                                               | risk                                                     |
| -------- | -------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------- |
| E0       | land `rust-resolution.nix` + `flake.rustResolutionPlan`; no build change                                             | none; validate classes/meets/costs against the lock      |
| E1       | `base ? null` seam + `lockMode="omit"` + `mkResolutionDepsBase`; **singleton per-member class nodes**; `base = C(m)` | medium; this is the pure G4 fix; gate `resolution-fresh` |
| E2       | equality classes (hash-consed nodes, class-derived `pname`)                                                          | low; identical maps already validated                    |
| E3       | opt-in `scope = pathComponents` + meet lattice + chaining                                                            | medium; locality trade documented; off by default        |
| E4       | mirrors use `local` class nodes; `mirror-parity`/`mirror-standalone` gates                                           | medium; Design M machinery                               |
| fallback | `resolutionMode="l"` → L; `useWorkspaceDeps=false` → legacy                                                          | —                                                        |

No package `default.nix` author change is required through E4 (all new arguments
are optional and defaulted).

## 14. Validation spikes and gates

Must pass before the corresponding stage:

- **R1 (closure identity)** a stub class node resolves the **identical** closure
  and versions as the real `-p m` source (`cargo metadata --offline` diff);
  extend the verified `stub-agent` to a path-dep member (`manager` with an
  `agent` stub).
- **R2 (zero residual)** `L(m)` logs no `Compiling <external>` for a crate whose
  map is in `C(m)` (the freshness gate, fail-closed in CI).
- **R3 (locality)** edit one member's `Cargo.toml` (add/remove/feature-change);
  `nix derivation show` must show only that class node (+ dependents) changing;
  every other class node/member drv byte-identical. Also `.rs` content and `.rs`
  add/remove.
- **R4 (vendor-root, already proven here)** two nodes with different vendor
  roots never reuse artifacts; record as the design constraint preventing
  cross-scope chaining.
- **R5 (meet reuse)** in `fused`, `L(m)` inherits `F(meet)` with no external
  recompiles of the meet's closure.
- **R6 (exactness)** `cargo metadata --offline -p m` inside `L(m)` is identical
  to the unmodified workspace's resolution for `m` (no added/moved versions).
- **R7 (no IFD)** `nix eval --option allow-import-from-derivation false` for
  every package; the planner has no unguarded `readFile`/`readDir`/`pathExists`.
- **R8 (24-member curve)** run `analyze_nodes.py` over the 24 manifests; record
  class count, `E`, `U`, and the predicted `local`/`fused` factors; gate any
  `fused` default on it.
- **R9 (G10 parity)** mirror `mkPackage { pkgs; base = C(m) }.drvPath ==`
  in-repo member `drvPath` in `local` mode.
- **R10 (lock locality)** a lock version bump inside class `k`'s closure changes
  only `k`'s node/vendor; a lock change outside all closures changes nothing.
- **R11 (rollback)** `resolutionMode="l"` reproduces landed L drv paths.

Standard gates: `nix flake check`; all `checks`; `nix path-info -r` shows no
artifact archive in a deployed package's closure; eval tests for determinism,
"every member in exactly one class", no meet split, degrade-without-throw.

## 15. Complexity and maintenance budget

| piece                                                                              | est. lines | kind                                                                |
| ---------------------------------------------------------------------------------- | ---------- | ------------------------------------------------------------------- |
| `lib/flake/rust-resolution.nix` (parse, inheritance, `Eff`, classes, meets, prune) | ~330       | pure eval                                                           |
| `lib/flake/resolution-bases.nix` (stub source + `mkResolutionDepsBase`)            | ~120       | composition                                                         |
| `pkg-helper.nix` delta (`base`, `lockMode`, vendor/lock plumbing, passthru, warns) | ~120       | emitter                                                             |
| `mkWorkspaceSourcePath` `lockMode` + `mkCargoWorkspaceSource` option               | ~20        | emitter                                                             |
| eval tests + freshness gate                                                        | ~130       | tests                                                               |
| **total**                                                                          | **~720**   | reuses `buildDepsOnly`-equivalent phases; no new derivation library |

Rules: the planner never resolves features/versions or semver (drops to a
`degrade`); all lists sorted/deduped for stable hash-consing; the author API
grows only defaulted optional arguments.

## 16. Honest limits and non-guarantees

1. **No dedup at 5.** All five signatures are distinct and there are zero strict
   subset chains; `local` mode is exactly per-member cost (2.05×). Its win at 5
   is G4 locality and future equality/scope dedup.
2. **`agent ⊆ manager` is a closure, not a declaration-map, relation** (Fact B);
   it is not chain-savable under the sound pure-eval rule.
3. **Vendor-root fingerprinting** (Fact A) forbids cross-class chaining without
   a shared vendor, so `fused` trades sibling locality for compiles. Only
   `local` is strictly G4-exact.
4. **Pure eval cannot see feature unification or optional activation**; the map
   rule is sound but conservative, and any activation-sensitive member is
   `solo`.
5. **Pruned locks are `--offline`-safe, not `--locked`-safe**; the vendor is the
   version pin. Hand-pruning only drops over-approximations and must never move
   a version (spike R6).
6. **Lock locality depends on §4.4** (excluding the root lock from filtered
   sources). Without it, a shared-lock edit is global, which the requirement
   permits but which weakens the common "add a dep" case.
7. **24-member cost is projected, not measured**; `local` scales with distinct
   class count, so the repo's signature distribution dominates.
8. **No git deps, `[patch]`, or alternate registries** in v1 (degrade).
9. **`fused` is not mirror-compatible** by construction (scope union is a peer
   property); mirrors are `local`.
10. **In-repo path deps are not artifact-shared across class vendors** in
    `local` mode; the dependency's crate compiles in each dependent's layer
    (small, in-repo only). A shared component vendor restores that at the cost
    of component granularity.

## 17. Open questions for the council

1. Default scope: `local` (G4-exact, 2.05× at 5) vs `pathComponents` (1.88×,
   component locality). Recommendation: `local` default, `fused` opt-in.
2. Should `[workspace.dependencies]` edits be treated as one synthetic node
   (shared root table) to reduce duplication, accepting that they are global by
   contract?
3. Whether to fund the one mechanism that would reconcile Fact A with strict
   locality: exposing each closure crate as a stable per-crate path source
   (`[patch.crates-io]` or a per-crate registry) instead of a single directory
   vendor. crane already builds per-crate `downloadCargoPackage` FODs; a spike
   could show whether cargo then reuses across node maps without a shared
   vendor. High complexity; explicitly out of v1.
