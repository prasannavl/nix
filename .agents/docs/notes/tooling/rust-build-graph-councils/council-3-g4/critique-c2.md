# G4 critique c2 — HARSH (architecture / maintainability / scaling / G10-G11 / complexity)

Scope: input plans `tmp/design-g4/plan-e1.md` (KEYSTONE), `plan-e2.md`
(DELTA-LATTICE), `plan-e3.md` (CLASSNODE), `tmp/design-g4/research.md` +
`explore.md`, and the current plan
`.agents/docs/plans/dual-mode-rust-build-graph-2026-09.md` (Design M). Code
seams verified in `lib/flake/pkg-helper.nix` and crane rev
`7rradzysxg41b2yx7qnh2f2bw73py192`.

Requirement under test: member `Cargo.toml` semantic edit invalidates only `m`'s
own external closure + dependents; root `[workspace.dependencies]`/shared-lock
edits may be global; no IFD; G10 mirrorable standalone package flake; G11
`standalone == composed == in-repo`, no widening; simple/intuitive consumption
API; maintenance-light; scalable to 24; L kept as bit-for-bit rollback.

Verdict in one line: **all three E-plans correctly identify closure/class-scoped
bases as the only way to satisfy the member-locality clause, but each buys it
with a self-inflicted vendor blow-up, an over-built mode lattice, or a flawed
cost/edge analysis; none of them can honestly claim both cheap sharing and
mirror identity at 24.**

---

## BLOCKERS

### BLOCKER-1 — E1: the L rollback and the degradation path are not bit-for-bit, and can silently

force a full recompile (violates the explicit "keep L as rollback" requirement).

What. E1 §4.5 sets the member's crane attrs unconditionally:
`craneCommonAttrs = commonAttrs // { cargoLockParsed = lockOf m; cargoVendorDir = vendorOf m; }`.
But the legacy/L prefix it falls back to (`prefixNode = sharedDepsBase` when
`base == null`) is `mkSharedRustDepsBase` called with
`cargoVendorDir = craneCargoVendorDir` — the **full-lock** vendor
(`pkg-helper.nix:2306, 2349`). So with `base = null` (rollback) or on _any_ of
E1's §11 degradations ("falls back to L's `sharedDepsBase` for `m` only"), the
base is built against vendor V_full while the member layer is built against
`vendorOf(m)` (pruned). Crane's vendor hook embeds the absolute vendor path in
the registry source id (`configureCargoVendoredDepsHook.sh`:
`directory = "${cargoVendorDir}"`), so every external unit gets a different
fingerprint path and cargo recompiles everything — the exact Fact A effect E3
measured (`plan-e3 §1.2`: 28/28 recompiles on a different vendor root). Result:
the rollback drv is not L's, and the "degradation" is worse than the failure it
is meant to absorb. E1 itself calls shared lock/vendor "the single most
important wiring rule" (§4.3), then breaks it in §11.

Why it matters. The requirement explicitly demands L as the rollback; E1's
rollback both changes the drv and destroys cache locality. This is not a polish
item, it is a correctness-of-rollback failure.

Smallest fix. Couple lock/vendor selection to `base`: only set
`cargoLockParsed`/`cargoVendorDir` to the pruned values when `base != null` (or
a `resolutionMode != "l"` flag); when `base == null` keep
`resolvedCraneCargoLockAttrs`/`craneCargoVendorDir` exactly as landed. Assert
`base == null || (vendorOf m) == base.cargoVendorDir-path` at eval. E3 already
shapes this correctly (`plan-e3 §11`: defaults reproduce L; `resolutionMode="l"`
is the switch).

### BLOCKER-2 (context / current plan) — Design M's `component` default does **not** satisfy the

member-locality requirement for any multi-member component; `union` fails
globally.

What. `componentBase({agent,manager})` dummies a source containing **both**
member manifests (Design M §4.2, `selectedDirs = component.memberDirs`). Editing
`manager`'s manifest changes `componentBase`, and `agent`'s `memberLayer`
consumes that base (`prefixNode`), so an edit to the _dependent_ invalidates the
_dependency_ — a member that is not in `Edits(manager)`'s dependent set. Design
M §12 concedes this ("member Cargo.toml external edit → that component's base +
its members"). The current default `union` is globally invalidating.

Why it matters. This is the requirement's core clause, and it is why E1/E2/E3
exist. If the council's plan is Design M as written, it is non-compliant;
per-member/per-class (or closure) granularity is **mandatory**, not a cost
optimization.

Smallest fix. Adopt per-member (or per-class) bases _inside_ components (i.e. E2
Stage 1 / E3 E1 / E1 K1), and keep component mode only as an explicitly
documented compromise. State the compile-once regression (below) as the accepted
price. Do not present `component` as the G4 answer.

---

## P1 — architecture and analysis

### P1-1 — The vendor-pruning wall is self-inflicted; the clean "both" design already exists

E1 §6.1 and E3 §1.2 both discover that per-closure/per-class **pruned** vendors
make the vendor store path differ, so crane's `.prev` chaining cannot reuse
units (Fact A). Both then pay for a workaround: E1 adds `shareVendor`, E3 adds
the meet lattice + `fused` scope (and admits `fused` is
`mirrorCompatible=false`). But pruning buys only store/network; it is **not**
required for correctness, and the requirement explicitly permits global lock
edits. The repo already builds one full-lock vendor per call
(`craneCargoVendorDir`) whose store path is a pure function of the root lock —
and a layout-preserving mirror copies that root lock byte-for-byte, so the
**same** vendor drv is reconstructible standalone. A single shared full-lock
vendor + per-node generated sources gives, simultaneously:

- class/per-member dedup via hash-consing of the node source (E3's equality
  classes, E2's canonical nodes);
- correct cargoArtifacts chaining along real dependency edges (agent→manager)
  because fingerprints align;
- `standalone == composed == in-repo` by drvPath, because the only extra input
  (the full lock) is present in every mirror;
- no `shareVendor`, no `fused`, no meet lattice — and global lock churn, which
  is _allowed_.

E2 already has this architecture (§5.1 keeps the full vendor; Stage 3 defers
pruning) — it is the cleanest of the three, and it should be the reference. E3
§17 Q3 names the general escape (per-crate stable `path`/`[patch.crates-io]`
sources so the source id is per crate, not per vendor root); that is the right
long-term answer if pruning must stay.

Smallest fix. Make the shared full-lock vendor the default in all three; keep
pruning as a store-only opt-in; drop `fused`/meets until a per-crate stable
source exists.

### P1-2 — E2's delta cost table is unsound on this repo; its headline ~15% win is unsupported

E2 §11.1/§11.2 claims "agent ⊆ manager (65 ∩; the only true subset)" and
computes "inclusion chain only = 693", "core + inclusion forest = 643". But the
actual manifests (`pkgs/tools/abird-host-agent/Cargo.toml`,
`.../abird-host-manager/Cargo.toml`) show `agent` declares `shlex` (absent from
manager) and `tempfile` only in dev, while manager declares `tempfile` in normal
— so under E2's own `⊑` rule (`plan-e2 §4.2`: every key of A must be in B with
compatible domain/spec) **agent is not a parent of manager**. E2's own locality
lemma (§4.2) therefore never selects the edge whose 65-unit saving its table
books. Correctly applied, at 5 members the `⊑` forest is empty and the only
saving is the peer-derived `core` meet (`{anyhow,clap,serde}` ≈ 25 units):
753→~728 = **~1.98×**, not 1.75×. E2's "one genuine closure-inclusion edge" is a
closure-level fact, not a declaration-map edge. The honest delta value at 5 is
~3%, matching its own admission that canonical is the complete answer.

Smallest fix. Recompute §11.2 with the `⊑` planner (not hand arithmetic); report
the empty forest; keep the correct recommendation (ship canonical, gate the
overlay) and delete the misleading 1.75×.

### P1-3 — E3's Fact B is wrong once `Eff` folds internal deps; E3 discards the one legitimate

chain, and its meet machinery is over-built for the real graph.

E3 §1.3 asserts "zero strict declaration-map subset relations at 5" by listing
**raw** agent and manager maps. But E3 §2.2 defines the node map as
`Eff(m) = E(m) ∪ ⋃_{d ∈ internalDeps*(m)} E(d)`. For manager,
`Eff(manager) = E(manager) ∪
E(agent)` (manager has a path dep on agent), and
`E(agent)` includes `shlex` (normal) and `tempfile` (dev). Every agent key is
present in `Eff(manager)` with identical spec, so **`Eff(agent) ⊆ Eff(manager)`
is a strict declaration-map subset** — the exact chain E1 §6 uses and E2's `⊑`
would (correctly) also select. E3's "treat meets, not chains" premise rests on
comparing raw maps, not the folded maps its design actually uses. Consequences:
E3's `local` default needlessly forgoes the agent→manager chain (a real
dependency edge, so it is locality-safe), and the meet/`fused` machinery is
solving a graph with one subset edge and two meets (agent/manager 64, nats 188)
that a simple scope/shared-vendor chain already covers.

Smallest fix. Redefine Fact B over `Eff` (folded); allow dependency-edge
chaining in `local`/`pathComponents` with the shared vendor (P1-1); keep
equals-classes only; drop the meet lattice to a P2 experiment.

### P1-4 — Mirror-safety is not uniformly reasoned: E1's `shareVendor` chaining is un-flagged

E3 honestly marks `fused` `mirrorCompatible = scope == "local"` (§10) and Design
M marks `union` non-standalone; E2 marks `warm_*` monorepo-only (§8). E1 does
not flag `shareVendor` at all, yet its own wording (§6.1) allows "one vendor
tree per host (full lock, **or a superset closure that contains all members
being chained**)". A superset-closure vendor is peer-derived; a standalone
mirror of the member's closure cannot reconstruct it, so
`standalone == composed` fails exactly as E3's `fused` does. Only the _global
full-lock_ vendor is mirror-reconstructible. The general rule the plans should
state: chaining is mirror-safe iff the parent/vendor's inputs lie inside every
participant's own closure (dependencies are; sibling meets/cores are not).

Smallest fix. Constrain `shareVendor` to the global full-lock vendor (or
per-crate stable sources), and emit `mirrorCompatible=false` for any narrower
scope. Fold this into P1-1.

### P1-5 — The lock story decides plan quality, and only E3 gets it right

The most common member semantic edit — adding a dependency — rewrites the shared
`Cargo.lock`. E1 keeps `keepLock = true` for the member source (§4.4), so
**every** member's `buildSrc` contains the full lock (`mkWorkspaceSourcePath`
always keeps `Cargo.lock`, `pkg-helper.nix:87`) and **every** `memberLayer` drv
changes on any lock byte. E1's §7 matrix nonetheless says the "inside
`closure(m)`" row leaves "unrelated layers no" — false, and inconsistent with
its own "member src keeps full lock" note in the sibling row. E2's canonical
default also takes the full lock in both node and member (Stage 3 defers
pruning), so a member dep-add is global there too. Only E3's `lockMode = "omit"`
(§4.4) + `replaceCargoLockHook` (verified: hook copies
`cargoLock`/`cargoLockParsed` over/into the tree) localizes the lock slice to
the affected class(es). Note the requirement tolerates global lock edits, but
the _value_ claim ("member edit local") is materially weaker in E1/E2 for the
common case.

Smallest fix. Adopt E3's `lockMode="omit"` on member and base sources, with
per-class pruned lock

- shared vendor; or state plainly that lock churn stays global and stop
  advertising lock locality. Fix E1's §7 matrix regardless.

### P1-6 — API/mode explosion, including a dead knob

Counts of user-visible modes/knobs: E1
`basePolicy ∈ {perMember, perSignature, chain,
component, union/legacy}` (naming
differs between §1 and §8.3) × `shareVendor` × `keepLock`, plus
`base`/`baseLabel`/`useWorkspaceDeps`; E3
`scope ∈ {local, pathComponents, fused, global}` × `resolutionMode` × `lockMode`
× `base`/`resolution`; E2 `baseMode ∈ {canonical, legacy}` × `deltaBases` ×
`aggressiveReuse` + `coreDeps` (8 states) plus the `parentBase` seam. At least
E1's `perSignature` is a **no-op at K1** (E1 §5.3: closure bytes differ for
every distinct member, so perSignature ≡ perMember until the deferred K2 stub
exists) — a user-visible mode that changes nothing is a maintenance trap. Design
M's single 3-value `basePolicy` is the simple baseline; the E-plans should not
regress it.

Smallest fix. One enum (`baseMode`) + at most one dedup bool; delete
`perSignature` until K2 ships; derive `mirrorCompatible`; put all policy in the
composition layer (as M/E2 already do).

---

## P2 — scaling, fidelity, migration, maintenance

### P2-1 — 24-member scaling is unsolved; every plan's floor is "distinct classes"

E1 perMember, E2 canonical, E3 local are the same floor:
`Σ over distinct class closures / union`. At 5 that is 2.05×; E3's honest model
gives 4.5× (12 classes) to 7.5× (24 classes); E1 projects 3–6×; E2's 1.4–2.2× is
inconsistent with both (see P1-2). Design M component mode is the same floor
when components are singletons, and cheaper only when components are large
(which re-introduces BLOCKER-2). Equality-class dedup is free but there are
**zero** equal maps at 5; mirror-safe chaining helps only along real path edges
(one edge here). Honest statement the council needs: at 24, cost grows with the
number of distinct resolved maps, and the only mirror-safe lever is
dependency-edge chaining over a shared vendor; budget 2×–7×, gate the default on
E3 R8 / E2 S7 / E1 S11.

Smallest fix. Default to equality-classes + dependency-edge chains over the
shared full-lock vendor; measure the real 24 manifests
(`analyze_nodes.py`/`cost_model.py`) before any `fused`/delta default; cap class
count with `component` fallback per-component.

### P2-2 — Generated-stub fidelity is unproven exactly where cargo is subtle; E1's real-source

base is the most faithful.

E3's `Eff` folds only dep tables; it cannot represent m's feature requests on an
internal dep, `[features]` `dep:`/`pkg/feat` activation, optional activation,
`[patch]`, renames, or build-script cfg. E2 folds too, or uses stub-members
(safer). E1 K1 keeps the **real** member manifests in the base, so cargo does
the true feature unification — the highest-fidelity design, at the cost of
`.rs`-structure sensitivity (`mkDummySrc` reads `src/`) and zero cross-member
dedup. Correctness is preserved by cargo fingerprints either way (a mismatch
only recompiles), but the "zero residual" gates and the cost model silently
degrade. E2's stub-member approach is the best generated-source compromise.

Smallest fix. Prefer stub-members over folding (E2 §3.4) where generation is
needed; gate with `cargo metadata -e features` diff (Design M V7), not a
`Compiling`-line grep (see P2-3).

### P2-3 — Gates and migration are themselves maintenance traps; 13 child flakes are unaddressed

by E1/E2/E3.

E1/E2/E3 lean on Design M for mirrors but never mention Design M §6.6's 13
existing child `flake.nix` wrappers, which live **inside member dirs** and are
therefore part of `builtins.path` — migrating them changes member source hashes
and the parity baseline. E1 §12 stage M and E3 E4 just say "M machinery". Also,
E2 R2 / E3 `resolution-fresh` propose fail-closed "zero external `Compiling`"
checks that are brittle (cargo stderr formatting, parallelism, documented
feature deltas are explicitly allowed, which weakens the gate to a diagnostic).
`mirror-fresh` (regenerate + byte-diff every mirror) is necessary but is
O(members) regenerated per commit and depends on the "no untracked bytes under
member dirs" policy.

Smallest fix. Inherit Design M §6.6 migration explicitly (do it before the
baseline); replace `Compiling` greps with a `cargo metadata -e features` diff;
key gates on changed components.

### P2-4 — Value vs. lines: the E-plans' budgets exclude the mirror layer and duplicate a

Cargo-semantics parser.

E1 ~600–740 lines, E2 ~410–630, E3 ~720 — and none includes Design M's ~220-line
generator or the full gate set; the combined system is ~900–1600 lines. Most of
it is pure-Nix re-encoding of Cargo manifest/feature/lock semantics (E3's
`rust-resolution.nix` ~330, E1's `rust-closures.nix` ~250–350), which Cargo
changes over time. Design M's ~120-line path-edge reader is dramatically
lighter. The durable v1 value of all three is only: (a) member-edit locality,
(b) mirror-identical bases, (c) a 2× cost. The parsing breadth is not required
for (a) or (b) if you stop at equality classes + dependency-edge chaining.

Smallest fix. Land the minimal canonical/equality-class + shared-vendor +
`lockMode=omit` layer (~250–350 lines total) with degrade-to-component; add
parse depth only when a real manifest requires it. Treat
`perSignature`/meets/`fused`/K2 as post-v1.

### P2-5 — Interaction with the union/REWEAVE rejection is honest but under-sold

Rejecting union base (and REWEAVE) means dropping repo-wide compile-once: 367 →
753 externals at 5 (2.05×), and the plans correctly state this (E1 §8, E2
§0/§16, E3 §9). The trade is explicit and, given G10/G11 and the member-locality
clause, necessary — the union base cannot be a standalone peer and REWEAVE makes
member features a peer function. Acceptable only with the measured 24 curve and
a per-component fallback. This is the strongest part of all three plans.

---

## What each plan gets right

- **E1 (KEYSTONE):** the closure is the correct unit; `cargoLockParsed` is a
  real, verified pure-eval seam for a pruned lock
  (`crane mkCargoDerivation.nix:65,76-77`, `vendorCargoDeps.nix:46`); base is a
  pure function of closure bytes ⇒ mirror-identical; the only plan that
  correctly exploits the one genuine chain (`agent→manager`, on closure + shared
  sub-map); honest about 2.05× and about K1's inability to dedup; API unchanged.
- **E2 (DELTA-LATTICE):** best headline and recommendation — canonical
  per-member bases are the complete G4 answer; delta beats them only modestly;
  ship canonical first, gate the overlay. Keeps the **shared full-lock vendor**,
  so fingerprints align and the Fact A wall never bites (the cleanest
  architecture of the three). Generated stub removes `.rs`-structure
  sensitivity. Best honesty on G11 ("different base drv, same units"); smallest
  API; explicit staged migration and two rollback levels.
- **E3 (CLASSNODE):** best diagnosis — measured Fact A (vendor root
  fingerprints) and the realization that per-class pruned vendors block
  chaining; the **only** plan with `lockMode="omit"`, hence the only one that
  truly localizes the common "add a dep" lock churn; explicit
  `mirrorCompatible=false`; `activationSensitive`/degrade rules; most honest
  24-member curve (up to 7.5×); names the per-crate stable-source escape hatch.
- **Design M (current plan):** best on G10/G11 mechanics and migration
  (generated layout-preserving mirrors, `mirror-fresh`/`parity`/`standalone`,
  the `base` seam actually reaching `callPackage`, 13-wrapper migration,
  equality matrix, sound `legacy` rollback). Its weakness is base granularity,
  not the mirror layer.
- **All three:** correctly reject union/REWEAVE, preserve `-p m` no-widening, no
  IFD, and keep the public author API additive.

---

## Recommendations (smallest coherent package)

1. Base granularity: per-member (or equality-class) inside path-connected
   components; `lockMode="omit"` + per-class pruned lock; **shared full-lock
   vendor** by default.
2. Chaining: dependency-edge only (parent ∈ closure), with the shared vendor;
   emit `mirrorCompatible=false` for any peer-derived sharing. No
   meets/`fused`/`perSignature` in v1.
3. One `baseMode` enum in the composition layer; `base` seam as in Design M/E2;
   L legacy path untouched and gated (`base == null` ⇒ full-lock L attrs).
4. Gates: `cargo metadata -e features` diff, not `Compiling` greps; migrate the
   13 wrappers before the first parity baseline.
5. Measure the real 24 manifests before defaulting anything; publish the 2×–7×
   budget.
