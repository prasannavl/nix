# E1 — KEYSTONE: Closure-Keyed Subset Bases (G4 locality plan)

Status: **design plan, implementation-ready v1 (K1) + a deferred dedup extension
(K2)**. Scope: `lib/flake/pkg-helper.nix` and a new pure planner. Repo
read-only; artefacts under `tmp/design-g4/`. Builds on landed L (shared
`.rs`-independent base, `memberLayer`, `mkCargoArtifactsJoin`) and on the
verified stage-1 facts in `tmp/design-g4/research.md` / `explore.md`. No IFD.
Consumption API unchanged. L (`useWorkspaceDeps = false`) kept as the
bit-for-bit rollback.

---

## 0. Decision in one paragraph

Replace L's single whole-workspace dependency base with **one dependency base
per member build-closure** (“subset base”): the base's source is filtered to
exactly `{m} ∪ transitiveInternalPathDeps(m)`, its `[workspace].members` is
rewritten to that set, and its lock and vendor tree are **pruned to the same
closure** (pure eval, no IFD). Every member layer then inherits its own base
plus the artifact layers of its in-repo dependencies (via
`mkCargoArtifactsJoin`), so a member `Cargo.toml` edit changes only that
member's base and its transitive dependents, while root
`[workspace.dependencies]` and lock edits stay global (tolerated). Bases are
shared across members **iff their base inputs are byte-identical**; the
pure-eval proxy is the resolved direct-declaration map of the closure (+
lock/profile/ target/toolchain), which is the _semantic_ justification, while
Nix's own derivation hash-consing is the exact mechanism. Closure-inclusion
chains (`agent ⊆ manager`) are exploitable with `cargoArtifacts` inheritance
only when the chained bases share a vendor-tree store path; per-closure pruned
vendors break that path, so v1 defaults to duplication and exposes a
`shareVendor = true` chain mode. Cost is
`Σ over distinct signatures
|closure| / |union|`: **753/367 = 2.05×** at the
current 5 members (measured), projectably ~3–6× at 24; the levers that reduce it
without widening are signature dedup and shared-vendor chaining.
Standalone-identical: because the base is a pure function of closure bytes, a
layout-preserving mirror produces the **same base drv**, so G10/G11 hold better
than under a union base.

**Codename: KEYSTONE** (the closure is the key).

---

## 1. Goals, restated against this design

| goal                   | mechanism                                                                                                                                           |
| ---------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| G4 locality            | base source/lock/vendor keyed on `closure(m)`; member manifest edit ⇒ `base(m)` + dependents only                                                   |
| no widening            | base member set == the member's `-p m` build set, so feature unification matches by construction (no peer members are ever added)                   |
| no peer-dependence     | a member's base input never contains a non-dependent sibling's manifest                                                                             |
| lock/root edits global | pruned locks still derive from the shared lock; a root declaration change rewires all affected closures (tolerated)                                 |
| no IFD                 | planner is `readFile`/`fromTOML`/`readDir` on evaluator-visible paths only; pruned lock passed as `cargoLockParsed` (a Nix value), not a derivation |
| simple API             | `mkRustDerivation { … }` unchanged; composition layer injects an optional `base`; `useWorkspaceDeps = false` is the rollback                        |
| scalable to 24         | one base per distinct signature; sharing by hash-consing; knobs `perMember`/`perSignature`/`chain`/`legacy`                                         |
| mirror-compatible      | per-closure bases are a pure function of closure bytes ⇒ layout-preserving mirror drv equality (G10/G11)                                            |
| keep L as rollback     | `base = null` / `useWorkspaceDeps = false` reproduces landed L exactly                                                                              |

---

## 2. Why the base must be closure-scoped (the exact bug)

Today `mkSharedRustDepsBase` receives `workspaceSource = mkRustWorkspaceSource`
over **all** `rustWorkspaceMembers`, builds `--offline --workspace`, and
`buildDepsOnly` sets `cargoArtifacts = null`. The base's drv references every
member `Cargo.toml` (via crane's `cleanCargoToml`), the whole `Cargo.lock`, and
the whole vendor tree. Therefore:

- editing any member manifest changes the base drv;
- `buildDepsOnly` cannot inherit, so the whole external union recompiles;
- every `memberLayer` names that base (directly or through `.prev`), so all
  member layers rerun.

KEYSTONE makes the base's **inputs a projection of `closure(m)`**, so an edit to
`m`'s manifest touches `base(m)` and the bases of members whose closure includes
`m` (i.e. dependents) — and nothing else.

---

## 3. Architecture and module boundaries

```text
                     pure eval (no IFD)                      build time
root Cargo.toml ─┐
member Cargo.tomls ┼─▶ lib/flake/rust-closures.nix (new, pure)
Cargo.lock       ─┘      ├─ members, glob-free
                         ├─ internal path-dep closure D(m)          (transitive)
                         ├─ parsed lock, pruned lock lock(m)        (Nix value)
                         ├─ external decl map ext(m) + signature sig(m)
                         └─ chain graph (optional)
                                    │
                                    ▼
lib/flake/closure-bases.nix (composition layer, emits derivations)
       baseFor(m) = buildDepsOnly { source=D(m); lock=lock(m); vendor=vendor(m); … }
                                    │  (injected as `base` through callPackage)
                                    ▼
pkgs/<m>/default.nix ─▶ mkRustDerivation { base = baseFor(m); … }
                                    │
                                    ▼
       memberLayer(m): src=buildSrc(m), cargoArtifacts=dependencyArtifacts(m)
                                    │
                         ┌──────────┴──────────┐
                         ▼                     ▼
           buildPackage(m) (deployed)   checks.{lint,test}(m)
```

New/changed pieces:

| piece                                                 | kind             | purpose                                                                                                                                       | budget         |
| ----------------------------------------------------- | ---------------- | --------------------------------------------------------------------------------------------------------------------------------------------- | -------------- |
| `lib/flake/rust-closures.nix`                         | new, pure        | members, closures, resolved decl maps, signatures, pruned locks, chain graph, diagnostics                                                     | ~250–350 lines |
| `lib/flake/closure-bases.nix`                         | new, composition | turn the plan into one `buildDepsOnly` per signature (and optional chained bases)                                                             | ~80–120 lines  |
| `pkg-helper.nix`                                      | modified         | add `base`/`baseLabel`, factor `cargoWorkspaceMembersPrePatch`, add `mkDepsBase` (inheritable), thread pruned lock/vendor, passthru, warnings | ~120 lines     |
| `lib/flake/packages.nix` / `root.nix` / `default.nix` | modified         | thread `closureBaseFor`/`pkgHelper` to `callPackage` (same seam as Design M)                                                                  | ~50 lines      |
| eval tests                                            | new              | locality, sharing, degradation, no-IFD                                                                                                        | ~100 lines     |

No new derivation kind: reuse `buildDepsOnly` (roots) and `mkCargoDerivation`
(chained nodes), plus the existing `mkCargoArtifactsJoin`.

---

## 4. Base-source / lock / vendor construction

### 4.1 Closure

```nix
# pure eval; src = repo root path (evaluator-visible)
members       = rustWorkspaceMembers src;                 # existing reader
manifestOf    = d: builtins.fromTOML (builtins.readFile (src + "/${d}/Cargo.toml"));
internalDirs  = d: [ d ] ++ pathDepsOf (manifestOf d);    # path deps in any dep table
closureDirs   = d: transitiveClosure internalDirs [ d ];  # closed, sorted, unique
```

`internalDirs` scans `[dependencies]`, `[build-dependencies]`,
`[dev-dependencies]`, and `[target.<cfg>.*]`, resolves each `path` lexically
against `d`, and keeps only paths that are workspace members. `closureDirs`
takes the transitive closure, so the base and the member build use the **same
member set** (manager ⇒ `{manager, agent}`). This is the exactness contract:

> `base(m)` builds `--workspace` over `closureDirs(m)`; `memberLayer(m)` builds
> `-p m` over a source filtered to the same set. Same packages, same manifests,
> same resolver inputs ⇒ the member layer requests exactly the external units
> the base compiled.

`closureDirs(m)` is the unit of locality. Any member not reachable in either
direction from `m` is absent from the base source and cannot invalidate it.

### 4.2 Pruned lock (pure eval, no IFD, no serialiser)

`mkCargoDerivation` already accepts **`cargoLockParsed`** (a parsed attrset) and
writes it with crane's `writeTOML` at build time; `vendorCargoDeps` also accepts
it. So pruning needs no TOML writer:

```nix
rootLock = builtins.fromTOML (builtins.readFile (src + "/Cargo.lock"));

pruneLock = lock: rootNames:
  let
    pkg  = lock.package;
    keyOf = p: "${p.name}@@${p.version}";
    byNv   = listToAttrs (map (p: { name = keyOf p; value = p; }) pkg);
    byName = groupBy (p: p.name) pkg;
    # "name", "name version", "name version (source)"
    parse  = d: builtins.match "([^ ]+)( ([^ ]+))?( \\(([^)]*)\\))?";
    roots  = concatMap (n: map keyOf (byName.${n} or [])) rootNames;
    step   = seen: k:
      if elem k seen then seen
      else if !(byNv ? ${k}) then seen
      else let m = parse …; in
        foldl' step (seen ++ [k]) (concatMap (resolveAll byNv byName) byNv.${k}.dependencies)
  in { inherit (lock) version; package = filter (p: elem (keyOf p) (foldl' step [] roots)) pkg; };

lockOf = m: pruneLock rootLock (map memberName (closureDirs m));
```

Notes and obligations:

- **Traversal follows every lock `dependencies` entry** (normal, build, dev) → a
  safe over-approximation; cargo drops over-approximated entries when the build
  runs without `--locked` (research §2). Ambiguous unversioned entries resolve
  to **all** candidate instances (over-approx, still valid).
- **Versions never move**: the vendored directory is the pin; pruning preserves
  every reachable `name@@version`. Validated below.
- Passing a **parsed** lock (not a string) keeps the whole planner IFD-free and
  avoids a hand-written TOML serialiser.

**Validated (this repo, this machine).** A Nix implementation of the above
reproduces the research numbers exactly (`tmp/design-g4/closure-probe.nix`):

```text
perMember = { hello-rust = 0; abird-host-agent = 65; nats-wrecking-ball = 216;
              abird-host-manager = 233; nats-http-bridge = 239; }
union = 367;  sum = 753;  duplication = 2.05x
closure(manager) == closure(manager ∪ agent) == 233   # agent ⊆ manager
```

### 4.3 Pruned vendor tree

```nix
vendorOf = m: pkgs.craneLib.vendorCargoDeps { cargoLockParsed = lockOf m; };
```

- Same parser → same vendor drv for equal signatures.
- The vendor dir is the **version pin** and the source path cargo fingerprints.
- **Both the base and the member layer must use the same `vendorOf`** (and the
  same `cargoLockParsed`), otherwise cargo's registry source path changes and
  _no_ external unit is reused. This is the single most important wiring rule.
- Cost win: agent's closure vendors 64 crates vs the repo's 367 (research §2).

### 4.4 Base derivation (`baseFor`)

```nix
baseFor = sig: let
  m  = representativeOf sig;
  ds = closureDirsOf sig;                          # sorted
  src' = mkWorkspaceSourcePath pkgs {
    inherit src;
    selectedDirs = ds;
    keepLock = false;                              # lock comes from cargoLockParsed
    name = "cargo-workspace-source";               # fingerprint invariant
  };
in pkgs.craneLib.buildDepsOnly {
  dummySrc      = pkgs.craneLib.mkDummySrc { src = src'; };
  pname         = "abird-rust-deps";               # neutral ⇒ hash-consing is exact
  version       = "0.1.0";
  cargoExtraArgs = "--offline --workspace";        # NOT --locked (pruned lock)
  prePatch      = cargoWorkspaceMembersPrePatch { members = ds; };
  cargoLockParsed = lockOf m;
  cargoVendorDir  = vendorOf m;
  nativeBuildInputs = profile.nativeBuildInputs or [];   # per closure/host, default []
  buildInputs       = profile.buildInputs or [];
  env = { CARGO_NET_OFFLINE = "true"; };
};
```

`cargoWorkspaceMembersPrePatch { members }` is the existing
`cargoWorkspacePrePatch` factored out of its `projectDir`-only shape (Design M
does the same); the member path keeps using
`cargoWorkspacePrePatch
{ projectDir; deps; }`.

`keepLock = false` is a new parameter of `mkWorkspaceSourcePath` (default
`true`, preserving every existing caller). It prevents the base's dummy source
from taking the **full** `Cargo.lock` as an input, so a lock edit outside a
closure does not change that base. The member source keeps `keepLock = true`
(proven, safe); crane's `replaceCargoLock` hook then installs the pruned lock
before cargo runs, and `cargoLockParsed`/`cargoVendorDir` are the shared ones.

### 4.5 Member wiring

```nix
# craneCommonAttrs for the member build
craneCommonAttrs = commonAttrs
  // { cargoLockParsed = lockOf m; cargoVendorDir = vendorOf m; };

prefixNode   = if base != null then base else <L behavior>;
depLayers    = map memberLayerOf internalDeps;
dependencyArtifacts =
  if depLayers == [] then prefixNode
  else mkCargoArtifactsJoin { name = pname; deps = [ prefixNode ] ++ depLayers; };
```

The join is required because a per-member base is a **deps-only** build: it
contains `m`'s externals but not the compiled code of `m`'s in-repo
dependencies, while the dependency's `memberLayer` contains that code but only
the dependency's base externals. The union of both is exactly what `-p m` needs;
`mkCargoArtifactsJoin` already exists for this fan-in (currently unused).

`cargoArtifacts = dependencyArtifacts` for `memberLayer`, `buildPackage`, and
`checks.lint`/`checks.test`; `checks.fmt` keeps `craneCommonAttrs` (no
artifacts).

---

## 5. Sharing / dedup rule and proof obligations

### 5.1 Rule

> Share one base across members **iff their base inputs are byte-identical**.
> The implemented key is the _resolved direct-declaration map of the build
> closure_ plus lock/profile/target/toolchain; Nix hash-consing is the exact
> mechanism, the key is the pure-eval **sufficient** proxy and the grouping
> label.

```nix
resolvedDecl c = for each dep table entry (normal/build/dev, per target cfg) of c:
  workspace = true substituted from root [workspace.dependencies]  (version,
  features ∪, default-features override, optional override, rename)
  external entries only (path entries are identity, not declarations)      ;
  key = (domain, target, key) -> { package; versionReq; features; defaultFeatures; optional };

sig(m) = sha256 (toJSON {
  closureDirs   = closureDirs m;             # sorted
  decls         = map resolvedDecl (closureDirs m);
  structural    = map structuralProjection (closureDirs m);  # [package]/[lib]/[[bin]]/paths, [features] external activations
  lockHash      = pruneLock rootLock roots;  # value hash, not full-lock hash
  profile; targetTriple; toolchainRev;
});
```

Two members share iff `sig(m1) == sig(m2)`; the base is built from one
representative. (In K1 with real filtered sources, `closureDirs` contains the
distinct member dirs, so **cross-member sharing is empty**; the rule still
governs “identical closure bytes ⇒ share”, which is what a K2 canonical stub
realises. See §5.4.)

### 5.2 Proof obligations

- **PO-1 (soundness of sharing).** `sig(A) == sig(B)` ⇒ the base source, pruned
  lock, vendor, and profile are byte-identical ⇒ the `buildDepsOnly` calls have
  identical inputs ⇒ identical `drvPath`. Nix enforces the conclusion; the key
  must be a _coarsening_ of the real inputs. Because `structural` and
  `closureDirs` are included, the key is not coarser than the source for K1.
- **PO-2 (no widening).** For every member `m`, the base's member set is exactly
  `closureDirs(m)` = the set `-p m` selects. Therefore the resolver sees the
  same root requirement table and the same feature-unification set in base and
  member. No non-dependent peer is ever added. This is the G10/G11 invariant.
- **PO-3 (no under-approximation of the lock).** `pruneLock` follows all lock
  `dependencies`; any ambiguity over-includes. Cargo with `--offline` and
  without `--locked` validates and repairs the lock inside the sandbox; the
  vendor tree pins versions. A `prune` that dropped a reachable package fails
  loudly (cargo offline cannot find it), it does not silently change versions.
- **PO-4 (fingerprint alignment).** Base and member share `cargoLockParsed`,
  `cargoVendorDir`, `CARGO_TARGET_DIR`, toolchain, and the
  `cargo-workspace-source` unpack name, so `cargo` reuses units rather than
  recompiling them. Spike S4 verifies.
- **PO-5 (conservatism).** A decl map difference that would resolve to the same
  units still produces separate bases (research §4); that is the accepted price
  of no-IFD exactness, not a correctness risk.

### 5.3 What can be shared without a stub

With K1 real filtered sources the only possible sharing is between members whose
**closure bytes** are identical, which cannot happen for distinct member
identities. So K1's cost is exactly “one base per member”, and the dedup rule
degrades to “never merge distinct members”. This is sound and is the floor.

### 5.4 K2 — canonical stub base (the only way to realise decl-map dedup)

To let distinct members with identical resolved decl maps share a base, the base
source must be a pure function of the decl map, not of the member's identity:

- generate a canonical workspace with one synthetic member per closure member,
  at canonical paths, each declaring exactly that member's **external** decl map
  (workspace inheritance resolved, `optional`/`default-features`/features
  concrete), and a cheap empty stub for each internal path dep proxy;
- the lock is deleted of path entries (vendored versions still pin); cargo
  regenerates path entries at build time;
- the base key is then the decl map alone, and `sig(A) == sig(B)` ⇒ identical
  base drv across _different_ members.

K2 is **deferred** and gated: research verified a hand-written stub for one
no-path-dep member against the real 65-package closure with zero drift, but the
general generator (optional activations via `[features]`, target tables, renamed
packages, `[patch]`, build-script cfgs) is unbuilt. Until the K2 spikes pass,
KEYSTONE uses K1 and does not claim dedup. The dedup rule in §5.1 is the
contract both implementations honour; K2 is the implementation that makes it
reachable for distinct members.

---

## 6. Closure-inclusion chains (`agent ⊆ manager`)

When `closure(A) ⊊ closure(B)` and the intersected declaration/feature map is
conservative, B's base can **inherit A's artifacts** so the shared units are
compiled once:

```nix
# optional, only under shareVendor = true
baseForChained = sigB: pkgs.craneLib.mkCargoDerivation {
  src = baseSourceOf sigB;                 # closure(B) filtered source
  prePatch = cargoWorkspaceMembersPrePatch { members = closureDirsOf sigB; };
  cargoArtifacts = baseOf sigA;            # nearest inclusion ancestor
  cargoVendorDir = sharedVendor;           # MUST be the same store path as A's
  cargoLockParsed = lockOf sigB;
  doInstallCargoArtifacts = true;
  doCheck = true;
  buildPhaseCargoCommand = "cargoWithProfile check --all-targets …; cargoWithProfile build …";
  checkPhaseCargoCommand  = "cargoWithProfile test --no-run …";
  env.CRANE_BUILD_DEPS_ONLY = 1;
};
```

`buildDepsOnly` cannot be used here: it hard-codes `cargoArtifacts = null`
(crane `buildDepsOnly.nix:64`). Add a small
`mkDepsBase { cargoArtifacts ? null;
… }` helper that mirrors `buildDepsOnly`'s
command sequence with inheritance (research §3). Inheritance is always **sound**
— cargo re-fingerprints every unit — so a wrong feature guess costs a recompile,
never a wrong binary.

### 6.1 The vendor-path blocker (why v1 does not chain)

Crane's vendor hook writes
`[source.nix-sources] directory = "${cargoVendorDir}"`
(`configureCargoVendoredDepsHook.sh`). The registry source path for every crate
is therefore `${cargoVendorDir}/<crate>`. `lock(A)` and `lock(B)` prune to
different closures, so `vendor(A)` and `vendor(B)` are **different store paths**
and every compiled registry unit has a different fingerprint path. Cargo will
**not** reuse A's units in B's base, regardless of `cargoArtifacts`. Chaining
therefore requires `vendor(A) == vendor(B)`:

- set `shareVendor = true`: one vendor tree per host (full lock, or a superset
  closure that contains all members being chained), shared by every base. Then
  A's units are reused. The trade: the vendor tree is keyed on the global lock,
  so a lock edit invalidates every base — explicitly tolerated by G4.
- `shareVendor = false` (default): per-closure pruned vendors, no chaining, cost
  `Σ|closure|`; best lock locality.

“A single node for the subset” (building only `base(A)` and using it for B, or
only `base(B)` for A) is **rejected**: using the superset for A widens A's
features (peer-dependence); using the subset for B under-primes B. Two nodes
(chained or duplicated) are required to stay exact.

Chain candidate test (pure eval): `closure(A) ⊆ closure(B)` **and** the shared
sub-map `decls(A) ∩ decls(B)` is pointwise equal (features/default-features),
**and** no member of `closure(B)\closure(A)` activates a feature on a crate in
`decls(A)`. Otherwise do not chain. A false positive only costs recompiles.

---

## 7. Invalidation matrix

Rows are the edit; cells say which derivations change. `Dep(m)` = transitive
in-repo dependents of `m`; “unrelated” = members not reachable either way.

| edit                                                  | `base(m)`                              | `base(unrelated)`   | `memberLayer(m)`                 | dependent layers | unrelated layers |
| ----------------------------------------------------- | -------------------------------------- | ------------------- | -------------------------------- | ---------------- | ---------------- |
| `m` `.rs` **content**                                 | no (crane launders; S7)                | no                  | yes                              | yes              | no               |
| `m` `.rs` **add/remove** under `src/`                 | **yes** (K1; `mkDummySrc` reads names) | no                  | yes                              | yes              | no               |
| `m` `Cargo.toml` dep-relevant                         | yes                                    | no                  | yes                              | yes              | no               |
| `m` `Cargo.toml` metadata (description/license/lints) | no (`cleanCargoToml`; S7)              | no                  | no                               | no               | no               |
| `m` internal `path` edge                              | yes + closure may grow/shrink          | no                  | yes                              | yes              | no               |
| root `[workspace.dependencies]`                       | yes (all)                              | yes                 | all                              | all              | all              |
| root `[workspace] members`                            | global                                 | global              | global                           | global           | global           |
| `Cargo.lock` (unrelated closure)                      | no (pruned lock)                       | no                  | yes (member src keeps full lock) | yes              | yes              |
| `Cargo.lock` (inside `closure(m)`)                    | `base(m)` only                         | no                  | `m` + `Dep(m)`                   | yes              | no               |
| new member                                            | global (root+lock)                     | global              | new + deps                       | —                | —                |
| toolchain / nixpkgs / crane                           | global                                 | global              | global                           | global           | global           |
| profile (`nativeBuildInputs`) for a closure           | that closure’s base                    | no if different key | that member                      | deps             | no               |

Properties this gives G4:

- **A member manifest edit is never global** (rows 3/5): only `m`'s base and the
  bases of `Dep(m)`, plus the corresponding layers.
- The only remaining global rows are exactly the ones the requirement
  **tolerates** (rows 6–8) plus structural/tooling changes.
- The `.rs` add/remove row is a known K1 inefficiency, still local to
  `{m} ∪ Dep(m)`; hardening by a manifest-only base source is spike S9.

---

## 8. Cost model and reduction levers

### 8.1 At 5 members (measured, `tmp/design-g4/closure-probe.nix`)

| mode                               | external compiles | vs union 367 |
| ---------------------------------- | ----------------- | ------------ |
| L union base                       | 367               | 1.00×        |
| KEYSTONE K1, no chain              | 753               | 2.05×        |
| KEYSTONE K1, chain `manager←agent` | 688               | 1.88×        |

Distinct signatures: 5 (all member decl maps differ). No dedup available at 5;
the chain saves agent's 65 duplicated units. Vendor trees are also duplicated
(agent 64 crates, plus per-member pruned trees).

### 8.2 Projection to 24

The right metric is `Σ over distinct signatures |closure(sig)| / |union|`, not
member count. It grows with (a) the number of distinct signatures and (b) the
depth/overlap of internal path edges. Anchors:

- 5 members, shallow, disjoint ecosystems → 2.05×.
- 24 members in 4–6 ecosystems with mostly-distinct signatures and shallow path
  edges → **~3–6×** (research §5). A single deeply-nested 24-chain is much worse
  (`O(n²)` closures) but unrealistic; a large weakly-connected component with a
  shared core is better.

### 8.3 Levers, none of which widen

1. **Signature dedup (K2).** Identical resolved decl maps share one base. Payoff
   at 24 depends on how many members are “thin binaries over the same stack”;
   measure with the planner (S1).
2. **Closure-inclusion chaining (O6)** under `shareVendor = true`: removes the
   duplicated intersection along inclusion edges. Payoff = Σ of the inclusion
   intersections; at 5 it is exactly the 65-unit `agent ⊆ manager` saving.
3. **Component mode as a cheaper fallback** (Design M): one base per
   path-connected component instead of per member. Cheaper (`Σ components` vs
   `Σ members`) but a member manifest edit then invalidates the whole component.
   Expose `basePolicy ∈ {perMember, perSignature, component, union/legacy}`; the
   operator trades locality for cost per component.
4. **Vendor pruning** is orthogonal: it reduces _store/network_ cost
   (`vendor(agent)` 64 vs 367 crates) even when the same crate is compiled in
   two bases.
5. **`[workspace.dependencies]` normalization** (already landed, W10) reduces
   accidental signature divergence; keep it.

### 8.4 Is 2× acceptable?

For the current 5-member repo it is the price of exact locality and no widening;
Design M reached the same order for its component mode. The design makes it a
**knob**, measured per repo, with `component`/`union` floors available. Default
to `perMember` only if the measured 24 curve is within budget; otherwise default
to `component`. Do not hide the cost.

---

## 9. G10/G11 (dual mode, mirrors) interaction

KEYSTONE is _more_ mirror-friendly than the union base, because the base is a
pure function of closure bytes:

- **Standalone-identical bases.** A layout-preserving mirror (Design M §6)
  copies root `Cargo.toml`, `Cargo.lock`, `.cargo`, and every member dir
  byte-for-byte at monorepo-relative paths. `mkWorkspaceSourcePath` +
  `mkDummySrc` then produce byte-identical filtered sources and `buildDepsOnly`
  calls, so `base(m)` has the **same `drvPath`** in monorepo and mirror. This is
  the `component`-mode equality of Design M, now at member granularity.
- **G11 adoption.** `externalPackagesFor` returns a function
  `{ pkgs, pkgHelper, base }:
  mirror.lib.${system}.mkPackage { inherit pkgs pkgHelper base; }`;
  the monorepo injects `base = baseFor(m)` (or the mirror computes its own
  identical base). Either path yields the same drv.
- **Mirror unit is the closure.** A member whose closure includes an in-repo
  dependency needs that dependency in the mirror; the planner already computes
  it, so the mirror generator emits the whole closure (equivalently the
  path-connected component).
- **Gates.** `mirror-fresh` (bytes), `mirror-parity` (drvPath equality for base
  and package), `adoption-parity` (composed == in-repo). The union base cannot
  pass standalone parity without injection; KEYSTONE's per-closure base can.
- **Non-Nix `cargo` in a mirror** still needs the Design M member-list rewrite
  (the base's `prePatch` is build-only). Unchanged.

---

## 10. Checks, devShell, pkgOps, internal deps, platform gating

- **checks.fmt** uses `buildSrc(m)` (`keepLock = true`) with no artifacts;
  unchanged.
- **checks.lint / checks.test / buildPackage** inherit `memberLayer(m)` and use
  the same `cargoLockParsed`/`cargoVendorDir`; `buildDepsOnly`'s
  `doCheck = true` primes dev/test units of the closure.
- **devShell** is unchanged (no base input).
- **pkgOps** is unchanged (it derives from the package drv).
- **Internal deps** use
  `mkCargoArtifactsJoin { deps = [prefixNode] ++
  depLayers; }`; the
  dependency's `passthru.memberLayer` contract is unchanged. Deduplicate
  `depLayers` and force the `internalDeps` guard on every shape (review P2-b/c).
- **Platform gating**: the composition filters `closureDirs` to host-available
  members (from `meta.platforms`) before building the base; a Darwin-only member
  never enters a Linux `--workspace`. `[target.<cfg>.*]` tables are preserved
  verbatim by `cleanCargoToml`, so cross-target deps do not activate on the
  wrong host. Bases are keyed by `(signature, host)`.

---

## 11. Diagnostics, degradation, rollback

- `passthru` on every member: `baseKey` (short sig), `closureDirs`, `depsBase`
  (`prefixNode`), `basePolicy`, `prunedLock`, `vendorCrateCount`.
- `flake.rustClosures` / `nix eval` output: members, closures, signatures,
  predicted external compiles (`Σ vs union`), chain edges, degradations.
- `lib.warn` (never throw) on: manifest parse failure, non-expandable glob
  (`rustWorkspaceMembers` already returns `[]`), `pruneLock` ambiguity,
  `craneLib == null`, missing `base` for workspace mode, profile mismatch.
- **Degradation**: any closure that cannot be computed for `m` falls back to L's
  `sharedDepsBase` for `m` only; a root-manifest failure degrades the whole repo
  to L. A bad chain edge is dropped (build fresh) rather than fail.
- **Rollback**: `useWorkspaceDeps = false` (per-package legacy) and
  `base = null` + `basePolicy = legacy` reproduce landed L bit-for-bit. The L
  base remains reachable (`sharedDepsBase` retained when `base == null`).

---

## 12. Staged migration

| stage    | change                                                                                                                                       | risk                       |
| -------- | -------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------- |
| **K0**   | planner only: `rust-closures.nix` + `flake.rustClosures`; no build change; unit-test closures/signatures against the lock; reproduce 753/367 | none                       |
| **K1a**  | add `base`/`baseLabel`, `mkDepsBase`, `keepLock`, `cargoWorkspaceMembersPrePatch`, passthru/warnings; default `base = null` (L)              | none                       |
| **K1b**  | `closure-bases.nix` builds per-member bases (unused) and `memberLayer` accepts `base`; build `perMember` behind a flag; verify S2–S7         | medium; validated by gates |
| **K1c**  | flip workspace members to inject `base = baseFor(m)`; wire the join for internal deps; run full checks and `nix flake check`                 | medium                     |
| **K2**   | optional canonical stub source + decl-map dedup (gated on S8)                                                                                | higher                     |
| **K3**   | optional `chain` under `shareVendor = true` (gated on S5)                                                                                    | medium                     |
| **M**    | mirror generation + `mirror-fresh`/`mirror-parity`/`adoption-parity` (Design M)                                                              | medium                     |
| rollback | `basePolicy = legacy` or `useWorkspaceDeps = false`                                                                                          | none                       |

No package `default.nix` changes for K0–K1c except the composition injection.
The `base` argument is added to `removeAttrs` so it never leaks into crate
metadata.

---

## 13. Validation spikes

- **S1** planner on the real repo: `closureDirs`, `sig`, pruned-lock counts
  match `tmp/design-g4/closure-probe.nix` (agent 65 / manager 233 / bridge 239 /
  wrecking 216 / hello 0; union 367); deterministic plan hash.
- **S2** `baseFor(m)` built from a filtered subset source + rewritten root
  members + pruned `cargoLockParsed` + pruned vendor builds
  `--offline --workspace` successfully; `Cargo.lock` inside is the pruned lock.
- **S3** `cargo metadata --offline` after the base/member build shows **no used
  version differs** from the full lock (V4 analogue).
- **S4 (fingerprint alignment)** with a `.rs` edit in `m`, `cargo build -p m`
  against `baseFor(m)` compiles **zero** externals; the base drv is unchanged.
- **S5 (chain)** under `shareVendor = true`, `baseFor(manager)` inheriting
  `baseFor(agent)` compiles only the non-shared units; under
  `shareVendor =
  false`, confirm _no_ reuse (documents the blocker). Gate
  `chain` on the former.
- **S6 (locality)** editing bridge's manifest changes only `base(bridge)` and
  bridge's own artifacts; agent/manager/wrecking bases and layers are
  byte-identical. Then edit agent's manifest and confirm manager changes
  (dependent) but bridge/wrecking do not.
- **S7 (invariance)** `.rs` content edit and description/license/lints edit
  leave `base(m)` byte-identical; `.rs` add/remove is recorded as a K1
  exception.
- **S8 (K2 stub)** generated stub for manager reproduces manager's real closure
  (233 packages) with zero version drift under `--offline`; only then enable
  dedup.
- **S9 (manifest-only base)** optional: base source filtered to manifests +
  `.cargo` + canonical `extraDummyScript` stubs; confirm `.rs` add/remove no
  longer changes the base and all targets still build (must not clobber the
  cleaned manifests; Design F’s warning).
- **S10** no-IFD: every package evaluates with
  `--option allow-import-from-derivation false`.
- **S11 (cost curve)** run the planner at 24 members (if available) and record
  `Σ|closure|/|union|` and per-signature dedup; decide the default policy.
- **S12 (join)** a member with ≥2 internal deps evaluates and reuses both layers
  through `mkCargoArtifactsJoin`.

---

## 14. Complexity budget

| piece                   | lines    | notes                                                              |
| ----------------------- | -------- | ------------------------------------------------------------------ |
| `rust-closures.nix`     | ~250–350 | pure; no `pkgs`/crane; hard stop and degrade if >400               |
| `closure-bases.nix`     | ~80–120  | one `buildDepsOnly` per signature (+ optional chains)              |
| `pkg-helper.nix` delta  | ~120     | `base`, `mkDepsBase`, `keepLock`, factored awk, passthru, warnings |
| composition seam        | ~50      | thread `closureBaseFor`/`pkgHelper`                                |
| eval tests + gate hooks | ~100     | locality/sharing/degrade/no-IFD                                    |
| K2 stub generator       | deferred | not in the v1 budget; must pass S8 first                           |

Rules: the planner never resolves features/versions; on ambiguity it
over-includes (lock) or degrades (base); all outputs sorted/deduped for stable
hash-consing.

---

## 15. Honest limits and risks

1. **~2× external compiles at 5, ~3–6× at 24.** This is the price of exact
   locality and no widening. Mitigated by signature dedup (K2), chain mode, and
   the `component`/`union` fallbacks; not eliminated.
2. **Pruned-vendor chaining is impossible by construction** (crane embeds the
   vendor path in cargo's source config). Chaining costs a shared vendor, which
   makes lock/vendor invalidation global. We expose this as `shareVendor`
   instead of pretending it is free.
3. **K1 cannot dedup distinct members** (their source bytes differ). The
   decl-map dedup rule is only realised by the deferred K2 canonical stub.
4. **K2 stub fidelity is unproven** beyond one no-path-dep member: optional
   activations, target tables, renames, patches, and build scripts can diverge.
   It is gated on S8 and is not on the critical path.
5. **`cargoLockParsed` + `--offline` (no `--locked`)** relies on cargo repairing
   an over-approximated pruned lock. Safe for this toolchain (research §2); a
   future cargo that refuses would need a canonical lock
   (`cargo generate-lockfile
   --offline` at build time) or a change to the
   pruning precision.
6. **`.rs` add/remove invalidates `base(m)` in K1** (`mkDummySrc` reads target
   structure). Local to `{m} ∪ Dep(m)`, so G4 holds, but it is not free; S9 is
   the hardening path.
7. **The join for internal deps materialises a full archive** and is currently
   only exercised by manager; its cost/regression coverage is thin (review
   P2-h). S12 covers it.
8. **24-member curve is projected, not measured.** Gate the default policy on
   S11; until then prefer `perMember` only for the components where the locality
   is worth it.
9. **Pure-eval equality is conservative** (PO-5); near-identical members pay
   duplication. That is deliberate: correctness first, no IFD.

---

## 16. References

- `tmp/design-g4/research.md`, `tmp/design-g4/explore.md`,
  `tmp/design-g4/closure-probe.nix` (validated Nix pruner),
  `tmp/design-g4/prune_lock.py`, `tmp/design-g4/cost_model.py`.
- `.agents/docs/notes/tooling/rust-build-graph-g4-locality-2026-09.md`.
- `.agents/docs/notes/tooling/rust-build-graph-dual-mode-goals-2026-09.md`
  (G10/G11), `rust-build-graph-decision-2026-09.md`,
  `rust-build-graph-review-2026-09.md`.
- `.agents/docs/plans/design-f-build-graph-2026-09.md`,
  `dual-mode-rust-build-graph-2026-09.md` (Design M mirror seam).
- crane rev `7rradzysxg41b2yx7qnh2f2bw73py192`: `lib/buildDepsOnly.nix`
  (`cargoArtifacts = null`), `lib/mkCargoDerivation.nix` (`cargoLockParsed`),
  `lib/mkDummySrc.nix` (eval-time `findCargoFiles`/`readDir`),
  `lib/setupHooks/configureCargoVendoredDepsHook.sh` (`directory = vendor`),
  `lib/setupHooks/inheritCargoArtifactsHook.sh`.
- `lib/flake/pkg-helper.nix`: `mkWorkspaceSourcePath` (`67`),
  `rustWorkspaceMembers` (`142`), `mkRustWorkspaceSource` (`167`),
  `mkSharedRustDepsBase` (`179`), `mkCargoArtifactsJoin` (`198`),
  `cargoWorkspacePrePatch` (`235`), `mkRustDerivation` workspace mode (`2235`+),
  `memberLayer` (`2400`+).
