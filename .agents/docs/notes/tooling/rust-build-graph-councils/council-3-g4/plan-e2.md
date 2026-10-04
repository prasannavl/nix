# G4 Plan E2 — Incremental Delta DAG (layered dependency bases)

Codename: **DELTA-LATTICE** Author lane: staff engineer E2 Scope: design only
(repo read-only except `tmp/design-g4/`). All experiments referenced live in
`tmp/design-g4/`; crane rev `7rradzysxg41b2yx7qnh2f2bw73py192`
(`installCargoArtifactsHook.sh`, `inheritCargoArtifactsHook.sh`,
`mkCargoDerivation.nix`, `buildDepsOnly.nix` read directly).

---

## 0. Headline finding (read this first)

**A current-tree parent edge and "the invalidation key of a node is its own
closure" are mutually exclusive in general.** A node that inherits
`cargoArtifacts = parent` takes the parent's _derivation path_ as an input, so
any edit that changes the parent changes the child's drv. This is exactly the O6
finding. The property the requirement wants — "edit member `m` invalidates only
`m`'s closure + dependents" — is recovered **iff every parent edge is a
closure-subset edge** (`closure(parent) ⊆ closure(child)`). Then a parent edit
is by definition an edit to a sub-closure of the child, i.e. the child _is_ a
dependent.

Consequences, all verified against the measured 5-member closures (§11):

| structure                               | parent edges | locality           | externals compiled (5 members, names) | factor               |
| --------------------------------------- | ------------ | ------------------ | ------------------------------------- | -------------------- |
| per-node canonical bases (no parents)   | none         | exact              | 753                                   | **2.05×**            |
| delta DAG, closure-subset forest + core | subset only  | exact              | 643                                   | **1.75×**            |
| delta DAG, overlap/spine chain          | non-subset   | **violates** G4    | 470–367                               | 1.28×–1.0×           |
| pinned cross-commit parents (O6)        | immutable    | exact + high reuse | →367                                  | →1.0× (out of scope) |

**The extra layering beats per-node bases by only ~15% at the current scale**
(2.05× → 1.75×) because there is exactly one genuine closure-inclusion edge in
the repo (`agent ⊆ manager`) and the _feature-safe_ shared core is tiny
(`{anyhow, clap, serde}` → 25 external package names at the current lock). The
large wins (1.0×–1.3×) are only reachable by (a) non-subset parent edges that
propagate invalidation to unrelated members, or (b) pinned cross-commit parents,
which are stateful and break mirror hermeticity. **Recommendation: ship
canonical per-member bases as the default (this alone satisfies G4 and G10/G11);
make the delta/lattice layering an opt-in `deltaBases` overlay whose headline
win is delta _storage_ plus the ~15% compile saving on genuine subset chains.**

This plan designs the full DAG as requested, then states the honest limits and a
staged migration that lands the G4-compliant part first.

---

## 1. Why the current base is global, and what "delta" can and cannot mean

Current chain (`lib/flake/pkg-helper.nix`):

- `rustWorkspaceMembers` (`:142`) reads root `[workspace].members`.
- `mkRustWorkspaceSource` (`:167`) → `mkWorkspaceSourcePath` (`:67`) selects
  **every** member.
- `mkSharedRustDepsBase` (`:179`) → `buildDepsOnly` with
  `cargoExtraArgs = "--offline --workspace"`.
- `memberLayer` (`:2383`) names that one base; `buildDepsOnly` hard-sets
  `cargoArtifacts = null` (`buildDepsOnly.nix:64`).

Therefore **any** member manifest change changes the one base drv → from-scratch
rebuild → every external recompiles → every member layer re-runs.

Two things are conflated in the word "delta":

1. **Delta source** — a per-node source that declares only the crates that node
   adds over its parent. This is **not** what we want, and it is a trap: feature
   unification is computed _within a single cargo resolution_. If the child's
   source omits a parent-compiled crate, the child's resolution does not know
   the parent enabled features on it, so the child's feature set differs and the
   inherited artifact is invalid/fingerprint-mismatched anyway.
2. **Delta artifacts** — the node's source declares its **full** resolved
   direct-declaration map; cargo _reuses_ the parent's already-compiled units by
   fingerprint, and `installCargoArtifactsHook` stores only the files this build
   wrote, with `$out/target.tar.zst.prev → parent/target.tar.zst`.

DELTA-LATTICE is entirely about (2). Per-node sources (1) are still mandatory,
but they carry full decl maps, not deltas. This is the single most important
implementation rule.

---

## 2. Architecture overview

```text
                 ┌───────────────────────────────┐
                 │ core node  (common decl specs)│   full archive, no .prev
                 └───────────────┬───────────────┘
        ┌───────────────┬────────┴────────┬───────────────┐
        ▼               ▼                 ▼               ▼
   base_agent      base_hello        base_wrecking     base_bridge   canonical nodes
   (+dev:tempfile)  (∅)               (async-nats/…)    (reqwest/…)
        │                                                   (only subset edges
        ▼                                                    allowed)
   base_manager
   (agent ⊑ manager)

memberLayer(m).cargoArtifacts = artifact(base_m)   [+ join with internal member layers]
```

Two layers of design, deliberately separable:

- **Canonical layer (default, G4-complete, G10/G11-safe).** One base node per
  distinct _resolved external declaration map_. No parents. Each node's inputs
  are a pure function of `m`'s own manifest + root `[workspace.dependencies]` +
  `Cargo.lock` + profile/target/toolchain. Editing `m` changes only `base_m`.
  Editing root/lock may change many (allowed).
- **Delta overlay (opt-in `deltaBases`).** Add a `core` node and closure-subset
  parent edges on top of the canonical nodes. Member layers use the delta node
  when it is enabled. This is monorepo-only and does not change package
  semantics; it does change base drv identity, so it is not cross-composition
  cache-shared with mirrors (see §12).

---

## 3. Node sources: resolved declaration map + generated stub workspace

### 3.1 Pure-eval resolved declaration map

New pure-eval reader (no IFD; only `builtins.fromTOML`/`readFile` on
evaluator-visible paths, same class as the existing `rustWorkspaceMembers`):

```nix
# lib/flake/pkg-helper.nix (new)
# Returns { externals = { "<kind>:<name>" = spec; }; members = { "<name>" = pkgName; }; }
# spec = { version ? str; features ? [str]; default-features ? bool; optional ? bool; package ? str; }
mkResolvedDeclMap = { src, projectDir, rootManifest ? (src + "/Cargo.toml") }:
  let
    root = builtins.fromTOML (builtins.readFile rootManifest);
    wdeps = root.workspace.dependencies or {};
    manifest = builtins.fromTOML (builtins.readFile (src + "/${projectDir}/Cargo.toml"));
    # fold `workspace = true` through wdeps, expand `package` renames,
    # classify path entries as `members`, everything else as `externals`.
    ...
  in { externals, members };
```

`spec` equality is the sharing key. Normalize before comparison: sort
`features`, drop unspecified `default-features` to `null`, keep `optional`
explicit. **The node key is the hash of the resolved map + lock +
profile/target/toolchain**, exactly research §4.

### 3.2 Generated stub workspace (per node, mandatory)

The node source is a synthetic workspace generated at eval:

```toml
# generated/<node>/Cargo.toml
[workspace]
resolver = "3"
members = ["stub"]                    # + one stub per internal path dep
[workspace.dependencies]              # verbatim copy of root [workspace.dependencies]

# generated/<node>/stub/Cargo.toml
[package]
name = "stub-<node-id>"; version = "0.1.0"; edition = "2021"
[dependencies]        <resolved externals, kind=dependencies>
[build-dependencies]  <resolved externals, kind=build-dependencies>
[dev-dependencies]    <resolved externals, kind=dev-dependencies>
[target.'cfg(...)'.dependencies]  <cfg tables, preserved>
# internal path deps become stub members, e.g.:
abird-host-agent = { path = "../stub-abird-host-agent", package = "abird-host-agent" }

# generated/<node>/stub/src/lib.rs   => empty (dummy), never compiled for real
```

Materialize with `pkgs.writeText` (or a small `runCommandLocal`) — the content
is known at eval, the drv path is a pure function of the map. Because the source
is already a stub, it is passed **directly as `src` to `mkCargoDerivation`**; we
do **not** run `mkDummySrc` and we do **not** use `buildDepsOnly`. This also
removes the crane `readDir` sensitivity to `src/lib.rs` / `src/bin/*` structure
(explorer note; improves on L).

Verified basis: `tmp/design-g4/stub-agent/` resolved the identical 65-package
closure as the real agent workspace offline (research §1b). The untested part —
path-dep stubs and cfg tables — is spike S1.

### 3.3 Why per-node sources are mandatory (the "one stub for all" trap)

If one source contained every member's stubs, editing any member manifest would
change that source and therefore **every** node (exactly today's global-base
failure). Each node gets its own `writeText`; Nix hash-consing then shares drvs
only when two members' resolved maps are byte-identical, which is the only safe
sharing. `hello-rust` (0 externals) produces a distinct empty node and
invalidates nothing but itself.

### 3.4 Internal path deps

An internal dep `d` contributes its external declarations to the dependent's
closure via feature unification, so the node must fold `d`'s externals. Two
equivalent options:

- **Folded inline (simplest):** union `d`'s resolved externals into the node's
  own tables, with `d`'s own `[dependencies]`/features. Loses nothing for
  externals; loses per-member source identity but the node is synthetic anyway.
- **Stub member (safer for optional/`workspace = true` feature propagation):**
  emit `stub-<d>` as a real workspace member carrying `d`'s tables, and declare
  the path edge. Cargo performs the same feature unification as the real `-p m`
  build.

Default to **stub member** and fold transitively; fall back to inline union if a
manifest shape is unsupported (degrade, §13).

---

## 4. Node lattice and planner

### 4.1 Nodes

- `core` (only when `deltaBases` is on): generated from `Decl_core`, the set of
  external declarations that (a) appear in **every** non-empty real member's
  resolved map, (b) have an **identical** spec (version req, features set,
  default-features, optional, package rename) in all of them, and (c) need no
  member-specific native input / platform gate. At the current tree
  `Decl_core = {anyhow, clap, serde}` (verified from the real manifests; W10
  feature normalization made `clap` uniform). Its external closure is **25
  package names**. Crates in the core are compiled once and inherited by every
  branch. The core drv depends only on root `[workspace.dependencies]`, the lock
  and the toolchain — all in the tolerated-global set — so it is byte-stable
  under member-local edits.
- `base_m` for each member `m`, source = `Decl(m)` (§3). Always built (canonical
  layer).
- `warm_m` (only when `deltaBases`): same source as `base_m`, but
  `cargoArtifacts = artifact(parent(m))`. This is the delta node.

Hash-consing: `base_m == base_m'` iff resolved maps are byte-identical (same
`writeText` content), regardless of member count. Node count at 5 = 6 (core +
5); at 24 ≤ 25 plus any identical-map sharing.

### 4.2 Parent edges — the only locality-safe rule

Define `A ⊑ B` (`A` is a safe parent of `B`) purely from resolved maps:

```text
A ⊑ B  ⇔  for every key k in A:
             k ∈ B
             ∧ A[k].version ∈ B[k].version          # same req (fixed lock ⇒ same instance)
             ∧ A[k].features ⊆ B[k].features         # B at least as wide (good reuse)
             ∧ A[k].default-features == B[k].default-features
             ∧ A[k].optional ≤ B[k].optional
```

**Lemma (locality soundness).** With a fixed shared `Cargo.lock`, resolution is
monotone in the set of direct dependency edges:
`A ⊑ B ⇒ closure(A) ⊆ closure(B)`. Therefore an edit to the closure of `A` is an
edit to the closure of `B`, i.e. `B` is a dependent. Parent edges built only
from `⊑` preserve "edit `m` invalidates `m`'s closure + dependents."

Non-subset ("overlap") edges give better reuse (`bridge`/`wrecking` share 193
units) but make an edit to one invalidate the other, which is **not** a
dependent. Those edges are therefore forbidden in the default plan and only
available under an explicit `aggressiveReuse = true` flag that documents the
locality trade (and is off by default).

### 4.3 Deterministic planner (pure eval, O(M·D))

```text
members := [m | isWorkspaceMember src m]                      # existing reader
maps    := { m -> mkResolvedDeclMap m }                       # incl. folded internal deps
core    := declCoreSpec maps                                  # identical across all non-empty
order   := sort members by (size maps[m].externals) asc, then name   # parents before children
placed  := {}
for m in order:
    cands := [ n | n ∈ placed, maps[n] ⊑ maps[m], n != core? ]
    parent[m] := argmax (closureEstimate maps[n]) cands       # or `core` if none
    placed  := placed ∪ {m}
```

`closureEstimate` is a cheap proxy (count of direct decls + a precomputed
package-name reachability hint from the lock, optionally). Tie-break
deterministically by node id. The planner emits
`{ core, nodes, parent, nodeOf }` and is exposed as `passthru.rustBasePlan`.

**Important:** parent selection needs only the _declaration_ maps, never the
resolved closures, so it stays pure-eval/no-IFD. The `⊑` rule is sound; it is
deliberately conservative (two members that resolve to the same units through
different declarations do not chain).

---

## 5. Exact construction and cargo invocations

### 5.1 Node derivation (crane `mkCargoDerivation`, not `buildDepsOnly`)

```nix
mkRustBaseNode = pkgs: {
  nodeId, src,                 # generated stub workspace (a derivation)
  cargoLockContents, cargoVendorDir,
  cargoArtifacts ? null,       # parent node drv, or null for core/canonical
  profile ? {},                # same profile/env/target as memberLayer (fingerprint-relevant)
  nativeBuildInputs ? [],      # only tools needed to build externals (pkg-config, ...)
}:
  pkgs.craneLib.mkCargoDerivation {
    pname = "abird-base-${nodeId}";
    version = "0.1.0";
    inherit src cargoLockContents cargoVendorDir nativeBuildInputs;
    inherit cargoArtifacts;
    doInstallCargoArtifacts = true;     # explicit; default is true
    doCheck = true;                     # cache dev-deps like the old shared base
    # NB: no doCompressAndInstallFullArchive -> delta archive is written
    buildPhaseCargoCommand = ''
      cargoWithProfile check --offline --workspace --all-targets
      cargoWithProfile build --offline --workspace
    '';
    checkPhaseCargoCommand = ''
      cargoWithProfile test --offline --workspace --no-run
    '';
    # installPhaseCommand defaults to `mkdir -p $out`; the install hook writes target.tar.zst
  } // profile
```

Notes that are load-bearing:

- `--offline`, **not** `--locked` (research §2: a subset/pruned lock fails under
  `--locked`; the vendor dir is the version pin). `cargoWithProfile` is crane's
  helper.
- `--workspace --all-targets` builds every stub member's normal+build+dev
  externals once.
- `cargoArtifacts = parent` is the **only** inheritance channel; `buildDepsOnly`
  would null it.
- `profile`/`env`/`CARGO_BUILD_TARGET`/toolchain are part of the fingerprint, so
  the node and the member layer must share them; the current shared base
  deliberately takes no per-package attrs to hash-conse, and this **changes** in
  DELTA-LATTICE: node identity must include them. Two members with different
  targets/profiles get different nodes (they already do).
- Do **not** set `doCompressAndInstallFullArchive`; only `mkCargoArtifactsJoin`
  sets it.

### 5.2 `.prev` mechanics (verified from hooks)

- Build-time: `inheritCargoArtifactsHook.sh` runs as a `postPatchHook`. It
  resolves `cargoArtifacts/target.tar.zst`, then follows
  `${preparedArtifacts}.prev` **recursively**, extracting ancestors first, then
  the node's own delta — reconstructing the full `target/`.
- Install-time:
  `installCargoArtifactsHook.sh::prepareAndInstallCargoArtifactsDir` sees
  `prev = parent/target.tar.zst`, symlinks
  `$out/target.tar.zst.prev → parent/target.tar.zst`, and tars only files with
  mtime newer than `SOURCE_DATE_EPOCH` (the delta cargo wrote this build).
  Reused units remain symlinks to the parent archive and are not re-stored.
- Net: each node's output is O(delta); the full target is materialized only
  transiently at build time. Storage is therefore roughly union-sized across the
  forest, not Σclosure.
- A core node has no parent → full archive (one full copy, unavoidable).
  `memLayer` consumes `artifact(base_m)` exactly as it consumes `sharedDepsBase`
  today.

### 5.3 Member layer, checks, internal deps

```nix
artifactOf = node: if deltaBases && node.warm != null then node.warm else node.base;

dependencyArtifacts =
  if internalDeps == [] then artifactOf nodeOf.${pname}
  else if length layerDeps == 1 then
         # keep L's real-code reuse, but also expose the delta externals:
         mkCargoArtifactsJoin { name = pname; deps = [ (artifactOf node) (head layerDeps) ]; }
  else mkCargoArtifactsJoin { name = pname; deps = [ (artifactOf node) ] ++ layerDeps; };
```

- `memberLayer` still runs `cargoWithProfile build --offline -p <pname>` on the
  real filtered source; it inherits its node's externals and compiles only real
  member/internal code.
- `mkCargoArtifactsJoin` is needed when a member has an internal dep, because
  the node chain and the real-code layer are two separate `.prev` chains and
  crane supports one. Today exactly one edge exists (`manager → agent`), so one
  join. (Research P2-h flags the join as unprobed; S4.) **Alternative accepted
  trade:** skip the join and let the dependent layer compile the internal dep's
  _real code_ from source (tiny relative to externals). Both are designed;
  default to the join when exactly one internal dep and its artifacts are
  available, else siblings.
- `checks.lint`/`checks.test` set `cargoArtifacts = memberLayer` (as today) so
  clippy/test reuse both node and layer artifacts; `checks.fmt` unchanged (no
  artifacts).
- `buildPackage` inherits `memberLayer`, keeping artifacts out of the runtime
  closure (measured ≈54 MB, unchanged).

---

## 6. Invalidation matrix

Rows = edit; columns = what changes. "Node" = base node drv; "Layer" = member
layer; "Desc" = descendants of the node in the parent forest.

| #  | Edit                                                       | core                      | base_m / warm_m                               | Desc(m)                          | other members' nodes | L(m)                                         | L(dep)                                             | Notes                                                              |
| -- | ---------------------------------------------------------- | ------------------------- | --------------------------------------------- | -------------------------------- | -------------------- | -------------------------------------------- | -------------------------------------------------- | ------------------------------------------------------------------ |
| 1  | member `m` `.rs` **contents**                              | stable                    | stable                                        | stable                           | stable               | rebuild                                      | rebuild if `m` is an internal dep                  | stub source ignores `.rs`; improves L's `readDir` caveat           |
| 2  | member `m` manifest: add/change external dep               | stable                    | **rebuild** (m only)                          | re-run, cargo no-op / delta only | **stable**           | rebuild                                      | rebuild if dep                                     | **G4 target case**                                                 |
| 3  | member `m` manifest: add/remove a `src/lib.rs`/`bin` entry | stable                    | stable                                        | stable                           | stable               | rebuild                                      | rebuild                                            | generated stubs never read member source                           |
| 4  | member `m` dev-dependency                                  | stable                    | rebuild (dev closure)                         | stable                           | stable               | rebuild                                      | rebuild (only if m is internal dep and build-deps) | dev edges do not propagate                                         |
| 5  | member `m` new **internal path dep** on `d`                | stable                    | rebuild (folds `d`)                           | re-run                           | stable               | rebuild                                      | rebuild                                            | join/sibling decision at §5.3                                      |
| 6  | root `[workspace.dependencies]` entry `X`                  | rebuild if `X ∈ core`     | rebuild iff `X` in map                        | re-run                           | may rebuild          | maybe                                        | maybe                                              | tolerated global                                                   |
| 7  | root `Cargo.lock` change (full lock as input)              | rebuild                   | all rebuild                                   | all                              | all                  | all                                          | all                                                | tolerated global; O5 pruned locks localize this                    |
| 8  | O5 pruned per-node lock                                    | only if X in core closure | only nodes whose closure contains changed pkg | re-run                           | only affected        | only affected                                | only affected                                      | optional enhancement                                               |
| 9  | root `members` list edit                                   | stable                    | stable                                        | stable                           | stable               | stable                                       | stable                                             | generated stubs exclude root `members`; improves option-(a) caveat |
| 10 | member `m` `useWorkspaceDeps = false` (rollback)           | stable                    | node unused                                   | —                                | stable               | legacy path                                  | legacy                                             | L rollback preserved                                               |
| 11 | dependency `d` rolled back (no `memberLayer`)              | stable                    | stable                                        | stable                           | stable               | join drops `d`'s layer, compiles from source | —                                                  | matches current degradation                                        |
| 12 | toolchain / cargo version / target / profile               | rebuild                   | rebuild                                       | all                              | all                  | all                                          | all                                                | node identity includes these                                       |
| 13 | `nativeBuildInputs` of `m` affecting externals             | stable                    | rebuild m only                                | re-run                           | stable               | rebuild                                      | maybe                                              | member-local over-invalidation accepted                            |
| 14 | `aggressiveReuse` non-subset edge chosen                   | stable                    | rebuild m                                     | **all later spine members**      | **violates G4**      | rebuild                                      | rebuild                                            | off by default                                                     |

Locality statement for #2 (the requirement):
`Δ(m) = {base_m} ∪ descendants(base_m) ∪ {L(m)}`. Unrelated nodes are
byte-identical.

---

## 7. Exactness argument

**Claim.** For a member `m`, `warm_m`/`base_m` compiles a superset (in package
instances) of the _external_ units that `L(m)` will reuse, with cargo-identical
fingerprints, so `L(m)` reuses all externals it can.

Proof sketch:

1. `base_m`'s source declares exactly the resolved external declaration map of
   `m`, with internal path deps folded as stub members carrying their own
   tables. Under the same lock, vendor, resolver, toolchain, target and profile,
   the external unit subgraph of `base_m` is isomorphic to the external unit
   subgraph of the real member workspace `{m} ∪ internalDeps(m)` — same package
   instances by fixed lock, same feature sets by identical direct edges (the
   stub folds the real edges).
2. A cargo unit fingerprint depends on crate source/version, feature set,
   profile, target, rustc, and the fingerprints of its dependency units —
   **not** on the dependent member's manifest. Identical (1) ⇒ identical
   fingerprints.
3. `inheritCargoArtifacts` materializes those units in `L(m)`'s `target/`;
   cargo's fingerprint check skips them.
4. `base_m` compiles no unit outside `closure(m)` (its source declares only
   `Decl(m) ∪
   internal decls`), so it never widens.

Caveats (must be validated, not assumed):

- **Feature unification through optional/`workspace = true`/cfg tables** must be
  replicated exactly by the generator, else units recompile (correctness
  preserved, efficiency lost). Spike S1/S9.
- **Dev-dependency edges** of internal deps: only relevant if the internal dep
  is built as a dependency; `cargo build -p m` does not enable `d`'s dev-deps.
  The generator must not fold `d`'s dev-deps into the node's normal closure (it
  may include them under a separate dev node if `-p m` tests need them).
- **Per-unit feature divergence** (research §4): two members can resolve the
  same crate differently; the `⊑` rule excludes chaining in those cases, so no
  false exactness is claimed.
- The map equality test is **sound but not complete**: members with different
  maps that resolve to the same units do not share, and pay a duplicate node.

---

## 8. Non-widening, G10/G11 interaction

- **No widening:** every node resolves only its own (folded) declaration map; no
  union of peers is ever formed. The core is a feature-identical subset, so it
  does not widen anyone; a member that needs a feature the core lacks simply
  recompiles that unit. This directly fixes the current transitive-union
  residual (research §7, decision-doc "residual").
- **G10 (mirror):** `base_m` is a pure function of `m`'s manifest + root
  `[workspace.dependencies]`
  - lock + toolchain/target/profile. A mirror with a single visible member
    computes the same `base_m` (the core/intersection degenerates, but the
    canonical node is unchanged). This is why **canonical nodes are the
    G10/G11-safe layer**.
- **G11 (seamless replacement):** with `deltaBases = false` (default), composed
  and standalone builds produce the **same `base_m` drv** and therefore the same
  cache key. With `deltaBases = true`, `warm_m` includes a parent drv that a
  single-member mirror cannot reconstruct, so the base drv differs while the
  compiled units and final package bytes are identical. The final `buildPackage`
  output is unaffected because the real source and its resolution are unchanged.
  **State this explicitly:** the delta overlay trades cross-composition
  _base-drv_ sharing for monorepo compile savings; it does not change package
  semantics.
- To give mirrors the option of the same sharing, expose `passthru.rustBasePlan`
  and a `basePlan` argument so a monorepo can import a mirror's canonical nodes
  (they match by construction), and reserve `warm_*` for the monorepo only.
- **Composition independence of `core`:** the core is derived from the peer set,
  so it is monorepo-scoped. A mirror does not use the monorepo core; it uses its
  own canonical node. The core is therefore an optimization, never a semantic
  input. (If a future goal requires cross-composition core sharing, declare the
  core explicitly in `[workspace.metadata]` so it is composition-independent.)

---

## 9. Diagnostics and degradation

- `passthru.rustBasePlan = { mode; core; nodes = { <id> = { src; drv; parent; members; declHash; }; }; nodeOf = { <pname> = <id>; }; }`.
- `lib.warn` (once per trigger) on:
  - member with a glob/unparseable root `members` entry → workspace mode off
    (existing behavior);
  - manifest shape the generator cannot faithfully reproduce (git deps,
    `[patch]`, exotic `target` tables, `package` renames) → that member degrades
    to legacy `buildDepsOnly`;
  - `deltaBases = true` with zero admissible parent edges (planner found no `⊑`
    edge) → warn that the overlay is a no-op;
  - `aggressiveReuse = true` → explicit warning that derivation locality is
    relaxed.
- Degradation ladder (each step is correct, less sharing):
  1. generated stub node (canonical) → full DAG;
  2. subset-source node (option (a): `mkWorkspaceSourcePath` +
     `cargoWorkspacePrePatch`, real cleaned manifests) if stub generation is
     unsafe for a member;
  3. legacy per-package `buildDepsOnly` (`useWorkspaceDeps = false`) for
     unparseable members;
  4. whole plan off → current L behavior.
- Never throw at eval for a member-specific manifest shape; throw only for API
  misuse (`internalDeps` entries without `projectDir`), matching the current
  contract.

---

## 10. Cross-commit / pinned parent (O6): feasibility and scope

Feasible mechanically: pass
`cargoArtifacts = builtins.storePath /nix/store/<pinned>` or a flake input
exporting a previously built node's archive; the path is fixed so member-local
edits do not change it, and cargo still validates fingerprints (stale pinned
units are simply recompiled when versions/features change). That yields high
reuse **without** inter-member invalidation propagation — the only design that
gives both.

But it is **out of scope for v1**, because:

- It requires publishing and pinning store paths (CI stateful step), and
  `builtins.storePath` requires the path to exist at eval — breaking hermetic
  eval and non-CI machines unless GC roots/pins are managed.
- It breaks mirror portability (a pin is machine/local-store specific) and
  G10/G11.
- The parent must be recomputed and re-pinned on every root/lock change,
  recreating a global key in the publishing step.

Design seam only: add an optional `parentBase ? null` to `mkRustBaseNode` and a
`passthru.rustBasePlan.pinnedParent` field, so a future CI can warm-start by
injecting a pinned parent. Default `null`. State clearly: **not a v1
deliverable.**

---

## 11. Cost analysis and 24-member projection

### 11.1 Measured closures (package instances, from `cost_model.py`, lock-verified)

| member             | external closure |
| ------------------ | ---------------- |
| hello-rust         | 0                |
| abird-host-agent   | 65               |
| nats-wrecking-ball | 216              |
| abird-host-manager | 233              |
| nats-http-bridge   | 239              |
| **union**          | **367**          |
| **Σ per-node**     | **753 (2.052×)** |

Inclusion structure (verified): `agent ⊆ manager` (65 ∩; the only true subset);
`bridge ∩ wrecking = 193` (neither subset); all other pairs non-nested. Common
direct decls across the four real members: `{anyhow, clap, serde}` → core
closure **25**.

### 11.2 Compile-work models (name-level; feature deltas add recompiles)

| model                                   | formula                                  | 5-member value | /union |
| --------------------------------------- | ---------------------------------------- | -------------- | ------ |
| per-node canonical                      | Σ_m                                      | closure(m)     |        |
| core + inclusion forest                 |                                          | core           | + Σ_m  |
| inclusion chain only (no core)          | agent + (manager\agent) + bridge + wreck | 693            | 1.89×  |
| core + **overlap** chain (wreck→bridge) | 25+6+202+196+46                          | 470            | 1.28×  |
| single spine (size-ordered)             |                                          | ∪ closure      |        |

(The last three marked models are **not** G4-locality-compliant.)

**Storage** (separate axis): canonical nodes each store a full archive (Σclosure
bytes); the delta forest stores ~union bytes across `.prev` chains plus one full
core archive. This is the overlay's most robust win and should be measured in
S4/S8.

### 11.3 24-member projection

The correct metric is not member count but the closure-nesting structure:

```text
factor = ( |core| + Σ_m |S_m \ S_parent(m)| ) / |∪_m S_m|
```

- Adding members that are singleton roots raises both numerator and denominator;
  the factor approaches the number of ecosystems when nesting is shallow.
- Adding members that nest (`crate-core ⊂ crate-http ⊂ crate-app`) adds almost
  nothing and lowers the factor for that ecosystem.
- Anchor: 2.05× per-node / 1.75× exact-forest at 5. Expect **~1.4×–2.2×** for a
  24-member repo of 4–6 ecosystems with shallow nesting, and **1.0×–1.3×** only
  under `aggressiveReuse` or pinned parents. **Recompute with
  `tmp/design-g4/cost_model.py` generalized to fold path deps and solve the `⊑`
  forest before enabling `deltaBases` by default** (spike S7). No default is
  switched on the basis of this projection.

### 11.4 Node count

At 5: 1 core + 5 member nodes = 6 (`hello-rust` and each real member distinct).
Two identical maps would collapse to one. At 24: ≤ 25 (+ subgroup nodes collapse
automatically). All nodes are pure Nix attrs; eval cost is O(M·D) per
`mkRustDerivation` call → O(M²·D) repo-wide at 24 (≈ 24²·15 ≈ 8.6k map
operations), negligible.

---

## 12. Integration

- **Base seam:** replace `mkSharedRustDepsBase` with `mkRustBaseNode` plus a
  plan producer (`mkRustBasePlan`). `workspaceMode`, `isWorkspaceMember`,
  `rustWorkspaceMembers`, `mkWorkspaceSourcePath`, `cargoWorkspacePrePatch`,
  `mkCargoArtifactsJoin` are reused. `internalDeps`/`deps`/`projectDir`
  semantics unchanged.
- **API (G5):** no new required argument. `mkRustDerivation` computes the plan
  from `src` + `projectDir` when workspace mode is on. Optional knobs:
  `baseMode ? "canonical"`, `deltaBases ? false`, `aggressiveReuse ? false`,
  `coreDeps ? null` (explicit override). Mirrors that cannot see the full member
  set simply get one canonical node.
- **Mirrors:** canonical nodes identical standalone/composed; `warm_*`
  monorepo-only; expose `passthru.rustBasePlan` for inspection and optional
  import.
- **Platform gating:** node identity includes system/target/toolchain
  implicitly; `core` must be platform-neutral (no `nativeBuildInputs`, no
  cfg-gated externals). Members whose externals are platform-specific get
  platform-specific nodes; use existing `meta.platforms`. Cross-compilation
  requires `CARGO_BUILD_TARGET` to be identical between node and layer.
- **Checks:** `lint`/`test` inherit `memberLayer` (unchanged); they benefit from
  node artifacts automatically. `fmt` unchanged.
- **L rollback:** `useWorkspaceDeps = false` remains the legacy path and is
  untouched. Add `baseMode = "legacy"` as an alias for the whole-plan off
  switch. `deltaBases = false` returns to canonical per-node (still
  G4-compliant), so there are two independent rollback levels.

---

## 13. Staged migration

- **Stage 0 — seams, no behavior change.** Factor
  `mkRustBaseNode`/`mkRustBasePlan`; add `mkResolvedDeclMap`; add
  `passthru.rustBasePlan` diagnostics; add eval tests. The current shared base
  is expressible as a single degenerate node (all-members map), so L behavior is
  preserved bit-for-bit.
- **Stage 1 — canonical per-node bases (default).** One node per distinct
  resolved map; member layers use `artifact(base_m)`. This **alone satisfies
  G4** and keeps G10/G11 identical. Measure locality (S2) and cost.
- **Stage 2 — core + inclusion forest (`deltaBases`).** Add `core` and `⊑`
  parent edges; wire `.prev` inheritance. Measure compile-work/storage reduction
  (S3/S4/S8).
- **Stage 3 — O5 pruned locks/vendor (optional).** Per-node pruned `Cargo.lock`
  so lock bumps localize; keep full vendor in v1.
- **Stage 4 — pinned parents (deferred/out of scope).** Seam only.
- **Stage 5 — remove L base** once canonical+delta is default and rollback is
  proven.

---

## 14. Validation spikes

| id  | spike                                                                                                                                                               | pass criterion                                                                                      |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| S1  | generator fidelity: agent (with `tempfile` dev) + manager (with path dep) stub workspaces build `--offline`; `cargo metadata` package/version set == real workspace | zero mismatch                                                                                       |
| S2  | locality dry-run in a scratch worktree: edit one member manifest, `nix build --dry-run` all packages                                                                | only that node + descendants + its layer/checks realize; core and unrelated nodes byte-stable       |
| S3  | core byte-stability: `nix eval .#.<m>.passthru.rustBasePlan.core.drvPath` before/after `.rs` edit and after a member manifest edit                                  | constant across `.rs`; unchanged for member-local edits                                             |
| S4  | `.prev` chain: inspect `$out/target.tar.zst.prev`, `nix-store -q --references`, archive sizes; join probe for manager→agent                                         | recursive inheritance works; no full-archive duplication except core/join; join evaluates           |
| S5  | exactness: build agent node then agent layer; count `Compiling <external>`                                                                                          | 0 external recompiles (allow documented feature deltas)                                             |
| S6  | G10/G11: build each member flake standalone and composed; compare canonical node drvPaths and final outputs                                                         | canonical drvPaths equal; outputs identical; no-IFD eval under `allow-import-from-derivation=false` |
| S7  | 24-member projection: run generalized `cost_model.py` over the real 24 manifests                                                                                    | produces per-node/forest/spine factors; decision gate                                               |
| S8  | storage: `du -sh` per node output and total store for canonical vs forest                                                                                           | forest total ≲ union; report                                                                        |
| S9  | feature-delta probe: bridge vs wrecking child node; count recompiled externals vs name-level prediction                                                             | quantifies the name/feature gap                                                                     |
| S10 | rollback: `useWorkspaceDeps=false` and `baseMode=legacy` eval/build                                                                                                 | succeeds, no regression                                                                             |

---

## 15. Complexity budget

| item                                                    | estimate                                                                     |
| ------------------------------------------------------- | ---------------------------------------------------------------------------- |
| `mkResolvedDeclMap` + normalization                     | ~60–90 lines                                                                 |
| stub workspace generator (incl. path stubs, cfg tables) | ~120–180 lines                                                               |
| planner (`⊑`, forest, core)                             | ~50–80 lines                                                                 |
| `mkRustBaseNode` + wiring in `mkRustDerivation`         | ~120–180 lines (mostly refactor of `sharedDepsBase`/`packageCargoArtifacts`) |
| diagnostics/passthru/tests                              | ~60–100 lines                                                                |
| **total new/refactored**                                | **~410–630 lines**, no new dependency, no IFD                                |
| eval cost                                               | O(M²·D) per repo eval; ≤ ~10k map ops at 24                                  |
| new drvs at 5 / 24                                      | 6 / ≤25 (+ joins for internal deps)                                          |
| rollback                                                | `useWorkspaceDeps=false` or `baseMode="legacy"`, both existing-shaped        |

---

## 16. Honest limits and recommendation

1. **The delta DAG does not meaningfully beat per-node bases on compile work at
   this scale.** 15% (2.05× → 1.75×) for exact-locality subset edges; the
   remaining gap to 1.0× requires either non-subset edges (which break the G4
   locality clause) or pinned parents (out of scope).
2. **The strongest immediate win is canonical per-member bases** (Stage 1):
   exact locality, no widening, G10/G11-identical, simple. It should ship first
   and is a complete G4 answer.
3. **The overlay's durable win is storage** (`.prev` deltas ≈ union bytes vs
   Σclosure) and the planner seam for a future pinned-parent/lattice design.
   Compile savings are real but modest.
4. **Feature deltas are the wildcard.** Name-level models (1.75×) will be worse
   in practice wherever a shared crate resolves differently between parent and
   child; S1/S9 measure the gap. The exactness rule (`⊑`) is conservative and
   may leave sharing on the table by construction.
5. **Root/lock edits remain global** as required; O5 pruned locks are the only
   lever to localize them and are deferred to Stage 3.
6. **Mirror base-drv sharing is lost under `deltaBases`** (parent identity is
   monorepo-scoped); semantics and final bytes are preserved. If the council
   weights G11 cache-sharing above monorepo compile time, keep
   `deltaBases = false`.
7. **Recommendation:** land Stage 0+1 (canonical), gate Stage 2 behind measured
   S7/S8 and the council's G11 weighting, and keep O6/O5 as documented seams.

---

## 17. Open questions for the council

- Is a ~15% external-compile reduction worth the added generator + planner
  complexity, given Stage 1 already satisfies G4?
- Does the council accept "same units and same final package, different base
  drv" as satisfying G11, or is base-drv identity mandatory (which would force
  `deltaBases = false` or pinned parents)?
- Is a single `mkCargoArtifactsJoin` for `manager → agent` acceptable, or should
  the dependent layer simply recompile the internal dep's small real code
  (sibling model)?
- Should the core be repo-declared (`[workspace.metadata]`) rather than
  peer-derived, to make it composition-independent for G11?
