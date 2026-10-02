# Design G4 — FINAL: **CLOSURE-BASES** (per-member closure bases)

Status: **final design, implementation-ready**, adjudication of G4 candidates E1
`KEYSTONE`, E2 `DELTA-LATTICE`, E3 `CLASSNODE` and critiques `C1`/`C2`.
Self-contained companion to Design M
(`.agents/docs/plans/dual-mode-rust-build-graph-2026-09.md`). Repo read-only;
this document only. Line refs: `lib/flake/pkg-helper.nix` (this repo); crane rev
`7rradzysxg41b2yx7qnh2f2bw73py192`.

**Chosen architecture in one line:** keep landed L's real, manifest-laundered
member sources and `--offline -p m` semantics; build **one dependency base per
member's own source closure** (member + its transitive in-repo path deps) from a
**real filtered source** and the **one shared full-lock vendor**, with optional
`cargoArtifacts` inheritance along genuine **closure-subset** edges; expose one
`base` seam and one repo-level `baseMode ∈ {member, union, legacy}`.

---

## 0. Decision summary

1. **Granularity is per member, not per component.** A member's base source is
   its own source closure `closure(m) = {m} ∪ transitivePathDeps(m)`. Component
   granularity cannot meet the G4 clause (editing one member's manifest would
   invalidate its siblings); `component` is deleted as a base mode.
2. **One shared full-lock vendor, shared by every base and every member layer.**
   Cargo fingerprints the absolute vendor root, so per-node pruned vendors break
   artifact reuse; the requirement explicitly tolerates global lock/vendor
   edits. Therefore no pruned locks and no pruned vendors in v1.
3. **Nodes are sourced from a real filtered source**, not a generated stub.
   Highest fidelity (cargo feature-unifies the real manifests), reuses crane's
   `cleanCargoToml`/`mkDummySrc`, and needs no Cargo-semantics re-encoding. The
   generated-stub (declaration-keyed) source is the documented, measured future
   dedup lever, **not** the v1 path.
4. **Chaining is automatic and un-knobbed**, and only along a real
   closure-subset edge (`closure(A) ⊆ closure(B)`); with the shared vendor this
   reuses `A`'s externals in `B`'s base. A peer-derived core/meet/union is
   rejected because a member edit could change it and invalidate dependents.
5. **API collapses to `base ? null` + `baseMode ∈ {member, union, legacy}`.** No
   `shareVendor`, `chain`, `scope`, `deltaBases`, `aggressiveReuse`,
   `perSignature`, `fused`, or meet lattice.
6. **L is the bit-for-bit rollback** (`baseMode = "legacy"` /
   `useWorkspaceDeps = false`), and `baseMode = "union"` is the zero-regression
   landing state.
7. **Cost is honest and gated:** measured `753/367 = 2.05×` at 5 members without
   chaining, `688/367 = 1.88×` with the one genuine chain, ~0 equality sharing.
   No default is enabled at 24 until the mandatory 24-member measurement gate.

---

## 1. Requirement, verified facts, and adjudication method

### 1.1 Requirement

- A **member** `Cargo.toml` semantic edit invalidates only that member's own
  external closure + its dependents.
- Root `[workspace.dependencies]` and shared `Cargo.lock` edits **may** be
  global.
- No IFD. Preserve G10 (mirrorable standalone package flake) and G11
  (`standalone == composed == in-repo`; no feature widening / peer-dependent
  semantics). Simple, intuitive consumption API. Maintenance-light. Scalable to
  24 members. Keep L as a bit-for-bit rollback.

### 1.2 Verified/decided facts this design rests on

- **F1 (vendor-root fingerprint).** A cargo `directory` source's `SourceId`
  embeds the absolute vendor path; byte-identical vendor content at a different
  root recompiles every unit (C1 exp A: 13/13; E3 §1.2: 28/28). Consequence:
  cross-derivation artifact reuse requires the **identical `cargoVendorDir`
  store path**.
- **F2 (shared vendor works).** With a shared vendor root, a child build
  inheriting a parent's `cargoArtifacts` recompiles only the delta (C1 exp B: 3
  new units; research: verified). Per-node pruned vendors destroy this.
- **F3 (per-node sources).** A base's inputs must be a manifest projection of
  its **own** resolved closure — never a shared all-stub or all-member source.
  Real filtered source `closure(m)` satisfies this; a peer union does not.
- **F4 (subset chains are the only sound chains).** `A → B` is locality-safe iff
  `closure(A) ⊆ closure(B)`: then an edit to `A`'s closure is an edit to `B`'s
  closure, i.e. `B` is a dependent. E3's "Fact B" (zero subset relations) is
  **false for the folded map** `Eff`: `Eff(agent) ⊊ Eff(manager)` holds, so the
  `agent → manager` chain is legitimate (critique C1 P1-2 / C2 P1-3).
- **F5 (cost).** Reproduced: per-member closures
  `{hello-rust 0, agent 65, wrecking-ball 216, manager 233, bridge 239}`, union
  `367`, `Σ = 753 = 2.05×`. `agent ⊆ manager` is the only closure-subset edge;
  `bridge ∩ wrecking = 193` is not a subset. 24-member projections in the three
  candidates disagree by 1.4×–7.5× and are **unmeasured**.
- **F6 (stub fidelity).** Generated stubs (features/default-features/optional/
  cfg/path/renames) are the main correctness risk; `.rs` add/remove still
  invalidates a `mkDummySrc` base unless the base is manifest-only.

### 1.3 Adjudication rule

Accept an architecture iff it delivers member locality, no widening, no IFD,
mirror identity, a small API, and a measured/cost-gated path to 24. Prefer
fidelity and low maintenance over unproven dedup. Every dedup mechanism that is
keyed on a **peer set** (union, peer-derived core, intersection meet, fused
scope) is rejected on the locality clause unless it is root-declared.

---

## 2. Architecture

```text
                      pure eval (no IFD)                         build time
root Cargo.toml ─┐
member Cargo.tomls┼─▶ rust-closures.nix (new, ~120 lines)
Cargo.lock       ─┘      ├─ members (glob-free)
                         ├─ path-dep edges
                         └─ closureDirs(m) = {m} ∪ transitive path deps
                                    │
                                    ▼
                  lib/flake/member-bases.nix (composition layer)
                    base(m) = mkClosureBase {
                      source  = mkWorkspaceSourcePath (closureDirs m);
                      prePatch= cargoWorkspaceMembersPrePatch (closureDirs m);
                      parent  = nearest closure-subset ancestor (or null);
                      lock    = FULL lock;  vendor = SHARED full vendor;
                    }
                                    │  injected as `base`
                                    ▼
            pkgs/<m>/default.nix ─▶ mkRustDerivation { base = base(m); … }
                                    │
                                    ▼
            memberLayer(m): real buildSrc(m), -p m, cargoArtifacts = base(m)
                                    │
                      ┌─────────────┴─────────────┐
                      ▼                           ▼
              buildPackage(m)               checks.lint/test(m)
```

New/changed pieces:

| piece                                                     | kind             | purpose                                                                                                                      | budget   |
| --------------------------------------------------------- | ---------------- | ---------------------------------------------------------------------------------------------------------------------------- | -------- |
| `lib/flake/rust-closures.nix`                             | new, pure        | members, path edges, `closureDirs(m)`, deterministic plan, diagnostics                                                       | ~100–140 |
| `lib/flake/member-bases.nix`                              | new, composition | one closure base per member; subset-parent selection; shared vendor; optional chaining                                       | ~90–130  |
| `lib/flake/pkg-helper.nix`                                | modified         | `base`/`baseLabel`, factor `cargoWorkspaceMembersPrePatch`, `mkClosureBase` (inheritable), passthru, warnings, `removeAttrs` | ~110     |
| `packages.nix` / `root.nix` / `default.nix` / `flake.nix` | modified         | thread `baseMode`, `closureBaseFor`, `pkgHelper` (Design M seam)                                                             | ~50      |
| eval tests + gates                                        | new              | locality, no-IFD, chain soundness, rollback, 24-cost report                                                                  | ~120     |

No new derivation kind: bases reuse `buildDepsOnly` (roots) and
`mkCargoDerivation` + `cargoArtifacts` (chained nodes). The component reader
`lib/flake/rust-components.nix` from Design M is **kept for mirror units only**;
it is not the base unit.

---

## 3. Base node model and sourcing decision

### 3.1 Node model — per member, content-addressed

- **One node per workspace member** `m`. The node's derivation inputs are a pure
  function of `closure(m)` plus the shared root/lock/vendor/toolchain/profile.
- Nodes are **not** grouped by signature class in v1. Two members share a node
  only if their filtered source trees are byte-identical, which cannot happen
  for distinct member directories; Nix hash-consing is the mechanism, not a
  mode.
- **A node's invalidation key is its own closure** `closure(m)`, because its
  source contains exactly `closure(m)` and nothing else (F3).

### 3.2 Sourcing decision — real filtered source (chosen), stub later (deferred)

**Decision: build each node from a real, filtered source**
(`mkWorkspaceSourcePath` over `closureDirs(m)`), then crane's `mkDummySrc`.

Why (and why not the generated stub):

1. **Fidelity.** `cargo` runs real feature unification over the actual member
   manifests. There is no re-encoding of `features` / `default-features` /
   `optional` / `[target.<cfg>.*]` / `package` renames / `[patch]` to get wrong.
   The generated-stub approach's only failure mode is cost (a mismatch
   recompiles), but a mismatch also silently weakens the "compile once" claim
   and needs a fidelity gate; the real source has no such gap.
2. **Maintenance.** It reuses crane's `cleanCargoToml`/`mkDummySrc` and the
   landed `mkWorkspaceSourcePath`/`cargoWorkspacePrePatch` seams. A stub
   generator is 120–180 lines of Cargo-semantics re-encoding that tracks a
   moving `cargo` (C2 P2-4). "Maintenance-light" is a stated goal.
3. **Mirror identity.** A layout-preserving mirror yields byte-identical
   filtered sources, so `base(m)` has the same `drvPath`
   standalone/composed/in-repo.
4. **The stub's only unique benefit is declaration-equality dedup**, which is
   _not required_ and is zero at 5 members anyway (F5). Its other benefit —
   removing `.rs` add/remove base sensitivity — is a **local** over-invalidation
   (`{m} ∪ dependents`), which does not violate the requirement (about
   `Cargo.toml`) and is documented in §7.

Accepted wart: **`.rs` add/remove** under `src/` changes `base(m)` because
`mkDummySrc` `readDir`s `src/`, `src/bin` (crane `mkDummySrc.nix:231-237`). This
is local to `{m} ∪ dependents`; content edits and metadata-only manifest edits
do not. A manifest-only/stub source is the hardening spike (G-S9) if the
24-member measurement demands it.

### 3.3 Closure definition

```nix
manifestOf  = d: builtins.fromTOML (builtins.readFile (src + "/${d}/Cargo.toml"));
pathDepsOf  = d: [ path deps in dependencies/build/dev/target tables,
                   resolved lexically, kept iff a workspace member ];
closureDirs = d: transitiveClosure ([ d ] ++ pathDepsOf d);   # sorted, unique
```

`closureDirs(m)` is the unit of locality. Any member not reachable through a
real path-dependency edge is absent from the base and cannot invalidate it.

### 3.4 Base derivation

```nix
# member-bases.nix
baseFor = m: let
  ds     = closureDirs m;
  parent = nearestSubsetAncestor ds;          # §5, or null
  filtered = mkWorkspaceSourcePath pkgs {
    inherit src; selectedDirs = ds;
    name = "cargo-workspace-source";          # invariant for crane fingerprinting
  };
in mkClosureBase pkgs {
  pname  = "abird-rust-closure-${hash8 ds}";  # neutral ⇒ hash-consing is exact
  source = filtered;
  members = ds;
  inherit parent;
  cargoLockContents = fullLock;               # the shared lock (not pruned)
  cargoVendorDir    = sharedVendor;           # the shared full-lock vendor
  profile = { };                              # v1: empty (native inputs deferred)
};
```

`mkClosureBase` is `mkCargoDerivation` (never `buildDepsOnly`), because
`buildDepsOnly` hard-codes `cargoArtifacts = null` (crane
`buildDepsOnly.nix:64`) and therefore cannot inherit:

```nix
mkClosureBase = pkgs: args: pkgs.craneLib.mkCargoDerivation {
  inherit (args) pname source members parent cargoLockContents cargoVendorDir;
  version = "0.1.0";
  src = args.source;
  prePatch = cargoWorkspaceMembersPrePatch { members = args.members; };
  cargoArtifacts = args.parent;               # null ⇒ root node
  doInstallCargoArtifacts = true;
  doCheck = true;                             # cache dev/test units, as L does
  cargoExtraArgs = "--offline --workspace";   # NOT --locked (see §4)
  buildPhaseCargoCommand = ''
    cargoWithProfile check --offline --workspace --all-targets
    cargoWithProfile build --offline --workspace
  '';
  checkPhaseCargoCommand = "cargoWithProfile test --offline --workspace --no-run";
};
```

---

## 4. Shared lock and vendor construction (exact)

**Decision: one full-lock vendor for the whole repo, shared by every base and
every member layer. No pruned locks, no pruned vendors in v1.**

```nix
resolvedCraneCargoLockAttrs = { cargoLockContents = builtins.readFile (src + "/Cargo.lock"); };
craneCargoVendorDir = craneLib.vendorCargoDeps resolvedCraneCargoLockAttrs;   # one drv/repo lock
```

- **Base node:** `cargoLockContents = full lock`,
  `cargoVendorDir =
  craneCargoVendorDir`.
- **Member layer:** exactly the same two values (the single most important
  wiring rule — F1/F2).
- **Member source:** keeps the lock verbatim (`mkWorkspaceSourcePath` always
  keeps `Cargo.lock`), as landed L.

Consequences, stated honestly:

- **A lock or `[workspace.dependencies]` edit is global** (changes
  `craneCargoVendorDir` and `cargoLockContents` ⇒ every base and every layer).
  The requirement explicitly tolerates this.
- A lock bump **inside** one closure cannot be localized without per-node pruned
  locks, and per-node pruned **vendors** would (a) break F2 chaining and (b)
  with a full vendor + under-approximated lock risk re-resolution drift across
  the 30 multi-version crate names (critique C1 P2-3). We therefore **reject**
  the pruned-lock/pruned-vendor route (`E1 shareVendor`, `E3 lockMode=omit` +
  per-class vendors) as a default: it trades a tolerated global for a real
  correctness/efficiency hazard. It remains a future store/network optimization
  only if paired with per-crate stable sources (crane's `downloadCargoPackage`
  `[patch.crates-io]` idea), which is out of scope.
- **`--locked` is not used on bases or members.** A subset `--workspace` with a
  pruned member list fails `--locked`; the full lock + shared vendor is the
  version pin. `--offline` only. (If a future cargo refuses the
  over-approximated lock, regenerate a closure lock; not assumed.)

---

## 5. Chaining (subset) rule and proof obligations

### 5.1 Rule

> `A → B` (base `B` inherits base `A`'s `cargoArtifacts`) **iff**
> `closureDirs(A) ⊆ closureDirs(B)` **and** `A ≠ B` **and** the vendor store
> path is identical (always true under the shared vendor). Among candidates,
> pick the closure with maximum `|closureDirs|`; tie-break on the closure hash.

Because `closureDirs` includes path deps, the only possible subset edges are
dependency → dependent (real in-repo path edges). Peer intersections are never
chained. At 5 members the sole edge is `agent → manager` (F4/F5), saving 65
units (`753 → 688`, `2.05× → 1.88×`).

This is deliberately **not a knob**: chaining is sound by construction, it is
free at run time, and it is mirror-safe because the parent's inputs are inside
the participant's own component (critique C2 P1-4).

### 5.2 Proof obligations

- **PO-1 (base key).** `base(m)`'s inputs are exactly
  `{root Cargo.toml, closure(m) manifests, full lock, shared vendor, toolchain,
  profile, target}`.
  No unrelated member dir is an input. Hence a member manifest edit changes
  `base(m)` and the bases of members whose closure contains `m` (dependents),
  and nothing else.
- **PO-2 (no widening).** `base(m)` builds `--workspace` over exactly
  `closureDirs(m)`, which equals the set `-p m` selects (member +
  `resolvedDeps`). Resolver inputs and feature-unification set are identical ⇒
  no non-dependent peer is ever added.
- **PO-3 (chain soundness).** `closure(A) ⊆ closure(B)` ⇒ an edit to `A`'s
  closure is an edit to `B`'s closure ⇒ `B` is a dependent. `cargoArtifacts`
  inheritance is a cache, never a resolution input: `B`'s source still declares
  its full closure, so a stale/wrong parent only causes recompiles.
- **PO-4 (fingerprint alignment).** Base and member layer share
  `cargoVendorDir`, `cargoLockContents`, `CARGO_TARGET_DIR`, toolchain, and the
  `cargo-workspace-source` unpack name, so cargo reuses units rather than
  recompiling them.
- **PO-5 (exactness / degrade).** Any parser/shape failure (glob member,
  unparseable manifest, crane null, non-member `projectDir`) degrades that
  member to the `union` base with a `lib.warn`; it never throws and never
  mis-builds.

---

## 6. Minimal consumption API

Collapse the mode explosion to **one repo-level enum and one optional
argument**:

```nix
# composition layer (flake.nix → root.nix → default.nix → packages.nix)
rustBaseMode ? "member"        # "member" | "union" | "legacy"

# mkRustDerivation (author surface, unchanged otherwise)
mkRustDerivation {
  base ? null;                 # derivation | null: injected closure base
  baseLabel ? null;            # diagnostics only
  …
}
```

Resolution:

| `baseMode` | `base` injected?             | behavior                             | G4      | purpose                 |
| ---------- | ---------------------------- | ------------------------------------ | ------- | ----------------------- |
| `member`   | yes, `baseFor(m)`            | one closure base per member          | **yes** | default target          |
| `union`    | no                           | landed L shared whole-workspace base | no      | zero-regression landing |
| `legacy`   | no, `useWorkspaceDeps=false` | L per-package `buildDepsOnly`        | no      | bit-for-bit rollback    |

- `base != null` **always wins** (mirror/G11 injection); an eval
  `assert base ==
  null || isDerivation base`.
- Add `"base"`, `"baseLabel"` to the existing `removeAttrs` list so they never
  leak into `buildArgs` (fixes E1 P2-8 / E3 B1).
- `useWorkspaceDeps = false` remains the per-package legacy escape and is
  exactly what `baseMode = "legacy"` sets.
- **Deleted knobs (rejected):** `shareVendor`, `chain`, `basePolicy`,
  `component`, `scope`, `deltaBases`, `aggressiveReuse`, `perSignature`,
  `fused`, `lockMode`, `component-profiles` as a mode. Chaining is automatic;
  the vendor is shared; the base is per member.

`passthru` per package adds `baseKey`, `closureDirs`, `depsBase` (= the injected
base), `baseMode`; `sharedDepsBase` is `null` when a `base` is injected.

---

## 7. Invalidation matrix

`Dep(m)` = transitive in-repo dependents of `m`. "unrelated" = no path edge to
`m` in either direction.

| edit                                                          | `base(m)`                    | unrelated bases | `memberLayer(m)` | dependent layers | unrelated layers |
| ------------------------------------------------------------- | ---------------------------- | --------------- | ---------------- | ---------------- | ---------------- |
| `m` `.rs` **content**                                         | no (`mkDummySrc` launders)   | no              | yes              | yes              | no               |
| `m` `.rs` **add/remove** under `src/`                         | **yes** (K-wart, §3.2)       | no              | yes              | yes              | no               |
| `m` `Cargo.toml` dep-relevant semantic                        | **yes**                      | no              | yes              | yes              | no               |
| `m` `Cargo.toml` metadata (`description`/`license`/`[lints]`) | no                           | no              | no               | no               | no               |
| `m` internal `path` edge change                               | yes; closure may grow/shrink | no              | yes              | yes              | no               |
| root `[workspace.dependencies]`                               | yes (all)                    | yes             | all              | all              | all              |
| root `[workspace] members`                                    | global                       | global          | global           | global           | global           |
| `Cargo.lock` (inside a closure)                               | all bases that read the lock | all             | all              | all              | all              |
| `Cargo.lock` (unrelated closure)                              | global                       | global          | global           | global           | global           |
| `.cargo/**`                                                   | global                       | global          | global           | global           | global           |
| new member                                                    | global (root + lock)         | global          | new + deps       | —                | —                |
| toolchain / nixpkgs / crane / profile                         | global                       | global          | global           | global           | global           |

Locality statement for the requirement (`Cargo.toml` semantic edit, row 3):
`Δ(m) = { base(m) } ∪ { base(d) : m ∈ closure(d) } ∪ { layer(m) } ∪
{ layer(d) : m ∈ closure(d) }`.
Every unrelated base and layer is byte-identical.

The only global rows are:

- the ones the requirement **tolerates** (`[workspace.dependencies]`, lock, new
  member, `.cargo`), plus
- toolchain/target/profile changes (unavoidably global).

`union` and `legacy` modes reduce to L's matrix.

---

## 8. Exactness and no-widening argument

**Claim (no widening).** For every member `m`, the base's `--workspace` member
set is exactly `closureDirs(m)`, which is exactly the set of directories in
`memberLayer(m)`'s `buildSrc` (`[projectDir] ++ resolvedDeps`). The resolver
sees the same root requirement table, the same manifests, the same lock, the
same vendor, the same toolchain and target in both. Therefore the base compiles
a subset of `m`'s resolved external units with cargo-identical fingerprints, and
`memberLayer(m)` recompiles only units whose fingerprints differ. No peer member
is ever added, so no feature can be enabled by a non-dependent sibling.

**Claim (mirror identity, member mode).** A layout-preserving mirror copies root
`Cargo.toml`, `Cargo.lock`, `.cargo/**`, and every selected member dir
byte-for-byte at the same monorepo-relative paths. `mkWorkspaceSourcePath` and
`mkDummySrc` then produce byte-identical filtered sources and identical
`mkClosureBase` calls, so `base(m)` has the same `drvPath` in monorepo, composed
mirror, and standalone mirror. The one extra artifact a mirror needs is a
pristine root manifest for Nix (the devShell may rewrite the member list for
humans) — critique C1 NOTE-3, stated, not hidden.

**Honest non-claims.**

- No claim of exactly-once for arbitrary feature requests: a dependent layer may
  still recompile a shared in-repo crate's real code (it is compiled in each
  dependent's layer under `-p m`), and a W10-style transitive feature residual
  can cause a bounded recompile. The base is a cache; it cannot widen.
- No claim of cross-member dedup (zero at 5; the stub is the future lever).

---

## 9. G10 / G11 interaction

| mode     | standalone base                                | composed == in-repo                         | standalone == in-repo                | notes                 |
| -------- | ---------------------------------------------- | ------------------------------------------- | ------------------------------------ | --------------------- |
| `member` | generated from `closure(m)`; layout-preserving | yes (`drvPath`)                             | **yes** (`drvPath`)                  | the G4/G10/G11 target |
| `union`  | mirror uses its own closure base               | yes only with base injected via `mkPackage` | semantically equal, not a cache peer | landing/rollout only  |
| `legacy` | L per-package                                  | yes                                         | yes                                  | bit-for-bit rollback  |

- **Mirror unit = path-connected component** (Design M §6.1). A member whose
  closure includes an in-repo dep needs that dep present; the closure reader
  already computes it.
- **Adoption seam** (Design M §7.1): `externalPackagesFor` returns
  `{ pkgs, pkgHelper, base }: mirror.lib.<system>.mkPackage { inherit pkgs
  pkgHelper base; }`;
  the monorepo injects `base = baseFor(m)`. Either path yields the same drv in
  `member` mode.
- **Chaining is mirror-compatible** in `member` mode because every parent edge
  is a real path-dependency edge inside the same component; a standalone mirror
  of that component reconstructs the identical chain. A peer-derived core/meet
  would not be reconstructible and is rejected for exactly this reason.
- Mirrors always run `baseMode = "member"`. `union`/`legacy` are monorepo-only
  convenience/rollback.

---

## 10. Diagnostics and degradation

- `passthru` per package: `baseKey` (short closure hash), `closureDirs`,
  `depsBase`, `baseMode`.
- `flake.rustClosures` (`nix eval`): members, path edges, `closureDirs`,
  predicted `Σ|closure|` vs `|union|`, chosen subset edges, warnings.
- `lib.warn` (never throw) on: non-expandable glob member; manifest parse
  failure; `craneLib == null`; non-member `projectDir`; a base source whose
  closure hash changed due only to `.rs` structure; profile mismatch.
- **Degradation ladder** (each step correct, less sharing):
  1. `baseFor(m)` per-member closure base;
  2. `union` (L shared base) for a member whose closure/manifest cannot be read;
  3. `legacy` per-package `buildDepsOnly` for an unreadable member;
  4. whole-repo `union` if the root manifest cannot be parsed.
- **Rollback:** `baseMode = "legacy"` (or per-member
  `useWorkspaceDeps =
  false`) reproduces landed L bit-for-bit;
  `baseMode = "union"` reproduces the current monorepo exactly.

---

## 11. Cost and the mandatory 24-member gate

### 11.1 Measured at 5 members

| mode                              | external compiles | factor vs union 367 |
| --------------------------------- | ----------------- | ------------------- |
| `union` (L)                       | 367               | 1.00×               |
| `member`, no chain                | 753               | 2.05×               |
| `member`, `agent → manager` chain | 688               | 1.88×               |

Equality dedup is **0** at 5 (all closures distinct; the `agent ⊆ manager` chain
is the only saving). Vendor trees are not duplicated (one shared vendor).

### 11.2 24-member projection — not a default input

The correct metric is `Σ over distinct closures |closure| / |union|`. It grows
with (a) the number of distinct member closures and (b) the depth/overlap of
real path edges. The candidates projected `1.4×–7.5×` and disagree because they
model different signature distributions; **none is measured**.

**Gate G-24 (mandatory before `member` is made the default or enabled at 24):**
run the closure reader over the real 24 manifests and record
`Σ|closure|/|union|`, the number of closure-subset edges, node count, and store
bytes; publish the curve. Until then `member` lands behind `union` and the 5/24
curve is reported, not assumed. If the measured curve exceeds budget, the
available non-widening levers are (in order): genuine chaining (already on) and
the deferred declaration-keyed generated-stub source (equality dedup). The
`component` fallback is **not** available, because it violates the G4 clause.

---

## 12. Staged migration (including the 13 child flakes)

| stage    | change                                                                                                                                                               | behavior/risk                                          |
| -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------ |
| **K0**   | land `rust-closures.nix` + `flake.rustClosures`; reproduce 753/367 and the `agent→manager` edge; no build change                                                     | none (pure eval)                                       |
| **K1**   | add `base`/`baseLabel` + `mkClosureBase` + factored `cargoWorkspaceMembersPrePatch` + `removeAttrs` + passthru; default `baseMode = "union"`                         | none; L unchanged                                      |
| **K2**   | `member-bases.nix` builds per-member bases; composition injects `base` for one pilot singleton (`hello-rust` or `nats-wrecking-ball`); verify gates                  | medium; measured by gates                              |
| **K3**   | flip remaining singletons, then `{agent,manager}`; wire G10/G11 mirror parity; migrate/delete the 13 child `flake.nix` wrappers **before** the first parity baseline | medium; wrapper migration changes member source hashes |
| **K4**   | flip repo default `baseMode = "member"` after G-24 + all gates                                                                                                       | decision gate                                          |
| **K5**   | optional: generated declaration-keyed source (dedup) and/or manifest-only source (`.rs` hardening), each gated on cost/fidelity                                      | post-v1                                                |
| rollback | `baseMode = "union"` then `"legacy"`                                                                                                                                 | bit-for-bit                                            |

**13 child flakes** (`pkgs/cloudflare-apps/llmug-hello`, `pkgs/cloudflare-apps`,
`pkgs/examples/hello-go`, `hello-node`, `hello-python`, `hello-rust-isolated`,
`hello-rust`, `hello-web-static`, `pkgs/support/nats-http-bridge`,
`pkgs/tools/nats-wrecking-ball`, `nixbot`, `abird-host-agent`,
`abird-host-manager`) live **inside member dirs** and are therefore part of
`builtins.path`; they must be migrated/replaced per Design M §6.6 and the parity
baseline refreshed in the same change. No other `default.nix` change is required
for K0–K4 (all new arguments are defaulted).

---

## 13. Validation spikes and gates

| id    | spike / gate                       | pass criterion                                                                                                                         |
| ----- | ---------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| G-S1  | closure reader on the real repo    | `closureDirs`/counts match `closure-probe.nix`: agent 65 / manager 233 / bridge 239 / wrecking 216 / hello 0; union 367; deterministic |
| G-S2  | `baseFor(m)` builds                | `--offline --workspace` succeeds; lock/vendor are the shared ones                                                                      |
| G-S3  | locality                           | edit one member manifest; only `base(m)` + `Dep(m)` bases/layers change; all unrelated drvs byte-identical                             |
| G-S4  | `.rs` invariance                   | content/metadata edit leaves every base byte-stable; `.rs` add/remove is **recorded** as the known local exception                     |
| G-S5  | chain                              | with shared vendor, `base(manager)` inheriting `base(agent)` compiles only manager's extra units (no agent-external recompiles)        |
| G-S6  | fingerprint alignment              | `memberLayer(m)` after a `.rs` edit logs zero external `Compiling` lines for units in `base(m)`                                        |
| G-S7  | no widening                        | `cargo metadata -e features --offline -p m` in `member` mode == unmodified workspace (no added/moved versions/features)                |
| G-S8  | no IFD                             | every package evaluates under `--option allow-import-from-derivation false`                                                            |
| G-S9  | (future) manifest-only/stub source | removes `.rs` add/remove base churn / enables dedup, fidelity confirmed                                                                |
| G-24  | 24-member cost curve               | measured `Σ                                                                                                                            |
| G-S10 | G10 parity                         | mirror `mkPackage { pkgs; base = baseFor m }` drvPath == in-repo member drvPath; `mirror-fresh`/`adoption-parity` green                |
| G-S11 | rollback                           | `baseMode="legacy"` reproduces landed L drv paths bit-for-bit                                                                          |
| G-S12 | 13-wrapper migration               | all wrappers migrated/deleted; `mirror-fresh` baseline refreshed                                                                       |

Standard: `nix flake check`; all `checks`; deployed package closure contains no
artifact archive; eval tests for determinism, every member in exactly one
closure, no throw on malformed manifests.

---

## 14. Complexity budget

| piece                  | lines        | notes                                                                    |
| ---------------------- | ------------ | ------------------------------------------------------------------------ |
| `rust-closures.nix`    | ~100–140     | pure; no `pkgs`, no crane, no Cargo feature/semver logic                 |
| `member-bases.nix`     | ~90–130      | `mkClosureBase`, subset-parent selection, shared vendor                  |
| `pkg-helper.nix` delta | ~110         | `base`, `mkClosureBase`, factored awk, passthru, warnings, `removeAttrs` |
| composition seam       | ~50          | thread `baseMode`/`closureBaseFor`/`pkgHelper`                           |
| eval tests + gates     | ~120         | locality/no-IFD/chain/rollback/24-cost                                   |
| **total**              | **~470–550** | no new derivation library, no Cargo re-encoding                          |

Rules: the planner never resolves features or versions; all lists sorted/deduped
for stable hash-consing; the public author API grows only optional args; if
`rust-closures.nix` exceeds ~200 lines, stop and degrade the affected member to
`union`.

---

## 15. Risks and explicit non-guarantees

1. **Cost.** `2.05×` at 5 (un-chained), `1.88×` with the one chain; at 24 the
   factor is unmeasured and could be 3×–7×. Gate G-24; no default flip before
   it. This is the price of exact locality and no widening.
2. **Lock/vendor churn stays global.** Explicitly tolerated; not localized in
   v1. Per-node pruned locks are rejected (drift + chain breakage).
3. **`.rs` add/remove** invalidates `base(m)` locally (`{m} ∪ dependents`). Not
   a requirement violation, but not free; G-S9 is the hardening.
4. **No cross-member dedup** in v1. The generated declaration-keyed source is
   the only non-widening lever for it and is deferred behind a fidelity gate.
5. **Feature residual (W10).** A dependent layer may recompile a shared in-repo
   crate's real code; the base cannot widen, but "exactly once" is not claimed.
6. **`--offline`, not `--locked`,** for bases; the shared vendor is the version
   pin. A future cargo that refuses an over-approximated lock would require a
   closure lock.
7. **Mirror root-manifest duality.** Nix needs the pristine root manifest;
   non-Nix `cargo` needs the member-list rewrite. The mirror ships both
   (devShell hook), as Design M already says.
8. **Native/profile axis** is untested; v1 profiles are empty (as L). A
   non-empty profile is keyed into the node, so it cannot silently widen.
9. **24-member eval cost** is bounded only empirically; report it in G-24.

---

## 16. How Design M changes

**Replaced:**

- `basePolicy ∈ {union, component, legacy}` →
  **`baseMode ∈ {union, member,
  legacy}`**; `component` is removed as a base
  policy (it fails the member clause). The component registry
  (`rust-components.nix`) is retained only to compute **mirror units** and
  path-dependency membership.
- `lib/flake/component-bases.nix` (`componentBase`) →
  **`lib/flake/
  member-bases.nix` (`baseFor(m)` closure bases + subset
  chaining)**.
- Design M's claim that component mode is the G4 answer → corrected: component
  mode is a documented compromise, not shipped.
- `pkgs/component-profiles.nix` base profile → optional per-node
  `base-profiles.nix` (empty in v1).

**Kept unchanged:**

- The `base` seam and its `removeAttrs`; `lib.<system>.mkPackage`; the
  `externalPackagesFor` adoption contract; layout-preserving generated mirrors;
  `mirror-fresh`/`mirror-parity`/`adoption-parity`; `--offline` + shared vendor;
  `basePolicy = legacy` rollback semantics (now `baseMode = "legacy"`); the
  13-wrapper migration; passthru/diagnostics; platform host filtering; the
  `union` default for the zero-regression landing.

**Net:** Design M's mirror/G11 layer is unchanged; only the **base granularity**
moves from per-component to per-member, and the vendor becomes explicitly the
one shared full-lock vendor.

---

## 17. Decision log

### 17.1 BLOCKERs

| #     | blocker                                                          | verdict    | reasoning / disposition                                                                                                                                                                                                           |
| ----- | ---------------------------------------------------------------- | ---------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| C1-B1 | E2's peer-derived `core` breaks G4 locality                      | **ACCEPT** | A member edit can change the peer intersection and invalidate unrelated members. **Core/meet/fused nodes rejected.** Nodes are per-member; only real closure-subset (dependency) chains are allowed.                              |
| C2-B1 | E1's L rollback/degradation is not bit-for-bit (vendor mismatch) | **ACCEPT** | Lock/vendor selection is coupled to `baseMode`: `base == null` / `legacy` / `union` use L's full-lock attrs exactly; `member` uses the same **shared** vendor, so there is never a base-vs-layer vendor mismatch. Assert at eval. |
| C2-B2 | Design M `component` default cannot satisfy member locality      | **ACCEPT** | `component` deleted as a base mode; per-member closure bases are mandatory for G4. Component kept only as the mirror unit.                                                                                                        |

### 17.2 P1 findings

| #                 | finding                                                                                  | verdict     | disposition                                                                                                                                                                                           |
| ----------------- | ---------------------------------------------------------------------------------------- | ----------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| C1-P1-1           | Vendor-root fingerprinting kills pruned-vendor chaining/dedup                            | **ACCEPT**  | Shared full-lock vendor by default (F1/F2); no pruned vendors, no `shareVendor` knob.                                                                                                                 |
| C1-P1-2 / C2-P1-3 | E3 "Fact B" false under the folded map                                                   | **ACCEPT**  | Use real closure sources; the `agent → manager` chain is enabled and sound (PO-3).                                                                                                                    |
| C1-P1-3           | E1's in-repo-dep artifact join is a no-op under pruned vendors                           | **ACCEPT**  | `member` mode uses `base(m)` alone (member layer compiles the in-repo dep's small real code); the join is not on the critical path.                                                                   |
| C1-P1-4           | `cargoLockContents` silently beats `cargoLockParsed`                                     | **ACCEPT**  | One lock source of truth (`cargoLockContents`, full lock); eval test asserts the realised lock.                                                                                                       |
| C1-P2-1           | Stub folding over-primes internal deps' dev edges                                        | **ACCEPT**  | Not applicable to the real-source v1; recorded for the deferred stub path.                                                                                                                            |
| C1-P2-2           | All 24-member projections disagree and are unmeasured                                    | **ACCEPT**  | Gate G-24 is mandatory before any default/24 enablement.                                                                                                                                              |
| C1-P2-3           | Pruned-lock key ignores `source`; multi-version drift                                    | **ACCEPT**  | No pruned locks/vendors in v1; drift class removed.                                                                                                                                                   |
| C1-P2-4           | Hidden `.cargo`/profile/`generate-lockfile` coupling                                     | **ACCEPT**  | `.cargo` global and documented; profile keyed into the node; `generate-lockfile --offline` is stable against the shared vendor.                                                                       |
| C1-P2-5           | E3 `classKey` omits path structure/lock slice                                            | **ACCEPT**  | Node keyed on `closureDirs` + real source bytes, which include path structure.                                                                                                                        |
| C1-P2-6           | `.rs` add/remove invalidates `mkDummySrc` base                                           | **ACCEPT**  | Documented local exception (`{m} ∪ dependents`); G-S9 hardening deferred; does not violate the `Cargo.toml` clause.                                                                                   |
| C1-NOTE-3         | Mirror root-manifest tension                                                             | **ACCEPT**  | Mirror ships a pristine root manifest for Nix; devShell rewrites for humans.                                                                                                                          |
| C2-P1-1           | Pruning is self-inflicted; shared full vendor + per-node sources is the clean design     | **ACCEPT**  | Adopted as the core architecture (real source + shared vendor + per-member nodes).                                                                                                                    |
| C2-P1-2           | E2's `⊑` forest is empty on raw maps; ~15% win unsupported                               | **ACCEPT**  | Chaining is defined on closure subsets (real path edges), not raw declaration maps; the measured save is the 65-unit `agent → manager`.                                                               |
| C2-P1-4           | `shareVendor` chaining may be mirror-unsafe                                              | **ACCEPT**  | Chaining restricted to real path-dependency subsets inside a component; `mirrorCompatible = true` for `member` mode.                                                                                  |
| C2-P1-5           | Only `lockMode=omit` localizes the common dep-add; E1/E2 advertise lock locality falsely | **PARTIAL** | Lock churn is **explicitly global and honest** (tolerated by the requirement). `lockMode=omit`/pruned locks are **rejected** as default because they reintroduce F1 breakage and multi-version drift. |
| C2-P1-6           | API/mode explosion, dead knobs                                                           | **ACCEPT**  | One `baseMode` enum + `base`; all other knobs deleted (`perSignature` removed as a no-op).                                                                                                            |
| C2-P2-1           | 24-member scaling unsolved; floor is distinct closures                                   | **ACCEPT**  | Gate G-24; non-widening levers only (chain + deferred stub).                                                                                                                                          |
| C2-P2-2           | Stub fidelity unproven; real source most faithful                                        | **ACCEPT**  | Real filtered source chosen for v1 (fidelity + maintenance).                                                                                                                                          |
| C2-P2-3           | Gates brittle; 13 child flakes unaddressed                                               | **ACCEPT**  | Migrate the 13 wrappers before the parity baseline; use `cargo metadata -e features` diffs, not `Compiling` greps.                                                                                    |
| C2-P2-4           | Value vs lines; Cargo-semantics re-encoding                                              | **ACCEPT**  | No Cargo re-encoding; ~470–550 total lines.                                                                                                                                                           |
| C2-P2-5           | Union/REWEAVE rejection cost honest                                                      | **ACCEPT**  | 2.05× at 5 stated; union kept only as rollout; REWEAVE remains rejected.                                                                                                                              |

### 17.3 Candidate verdicts

| candidate                | verdict                                              | reason                                                                                                                                              |
| ------------------------ | ---------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| **E1 KEYSTONE**          | **spine (adopted, hardened)**                        | Correct closure unit, mirror-identical; fix lock/vendor coupling and drop the ineffective join.                                                     |
| **E2 DELTA-LATTICE**     | **architecture adopted; core/delta rejected**        | Shared full-lock vendor + canonical per-node bases is the right skeleton; the peer-derived core and the unsupported forest arithmetic are rejected. |
| **E3 CLASSNODE**         | **diagnosis adopted; pruned vendors/meets rejected** | Best naming of the vendor-root constraint and the `local` locality model; its pruned vendors and meet/fused lattice are rejected.                   |
| **Design M `component`** | **rejected as base mode**                            | Fails the member-locality clause.                                                                                                                   |
| **union / REWEAVE**      | **rejected for G4**                                  | Peer-dependent semantics / global invalidation.                                                                                                     |

---

## 18. References

- `.agents/docs/notes/tooling/rust-build-graph-g4-locality-2026-09.md` (G4),
  `rust-build-graph-dual-mode-goals-2026-09.md` (G10/G11).
- `tmp/design-g4/research.md`, `tmp/design-g4/explore.md`,
  `tmp/design-g4/plan-e1.md`, `plan-e2.md`, `plan-e3.md`,
  `tmp/design-g4/critique-c1.md`, `critique-c2.md`.
- `tmp/design-g4/closure-probe.nix`, `cost_model.py`, `prune_lock.py`,
  `stub-agent/`, `vendor-agent/` (verified experiments).
- `.agents/docs/plans/dual-mode-rust-build-graph-2026-09.md` (Design M).
- `lib/flake/pkg-helper.nix`: `mkWorkspaceSourcePath` (67),
  `rustWorkspaceMembers` (142), `mkRustWorkspaceSource` (167),
  `mkSharedRustDepsBase` (179), `mkCargoArtifactsJoin` (198),
  `cargoWorkspacePrePatch` (235), `mkRustDerivation` (2103), `memberLayer`
  (~2400).
- crane rev `7rradzysxg41b2yx7qnh2f2bw73py192`: `lib/buildDepsOnly.nix`
  (`cargoArtifacts = null`, `:64`), `lib/mkCargoDerivation.nix`,
  `lib/mkDummySrc.nix` (`readDir` `src/`, `:231-237`),
  `lib/vendorCargoDeps.nix`,
  `lib/setupHooks/{configureCargoVendoredDepsHook,
  inheritCargoArtifactsHook,installCargoArtifactsHook}.sh`.
