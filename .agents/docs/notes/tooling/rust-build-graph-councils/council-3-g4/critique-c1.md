# C1 — HARSH CRITIQUE of G4 plans E1 (KEYSTONE), E2 (DELTA-LATTICE), E3 (CLASSNODE)

Axis: correctness / semantics / no-IFD / cost. Repo read-only; all new artifacts
under `tmp/design-g4/`. Evidence is from direct code reading + cargo 1.95
experiments run under `tmp/design-g4/scratch-c1/`. Line numbers:
`lib/flake/pkg-helper.nix` (this repo), crane rev
`7rradzysxg41b2yx7qnh2f2bw73py192`.

## 0. Experiments run (all reproduced here, not inherited from the plans)

| # | experiment                                                                                                             | result                                                                                                                                                                                                                            |
| - | ---------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A | stub-agent (13 check units), two **byte-identical** vendor roots `vendorA`/`vendorB`, same `CARGO_TARGET_DIR`          | `A→B`: **13 recompiles**; `B→A`: 13; `A→A`: 0. Symlink farm `vendorD -> vendorA/*` also 13. → **cargo fingerprints the absolute vendor root** (Fact A is true).                                                                   |
| B | core stub `{anyhow,clap,serde}` built into target `T`; then agent stub (superset) inheriting `T`, **same vendor root** | only 3 new `Compiling`: `libc`, `serde_json`, `zmij`; all 10 core units reused. → delta inheritance works **iff the vendor root is shared**.                                                                                      |
| C | `subset-agent` pruned lock (65 pkgs) + full vendor; `cargo metadata --offline` (no `--locked`)                         | resolves exactly 65 pkg-instances, lock **unchanged**, then `--locked` passes. Under-approximate by deleting `hashbrown 0.15.5` + full vendor → cargo silently **re-adds the same version** (no drift because the vendor has it). |
| D | pure-eval decl maps from the real manifests + folding of internal path deps                                            | **`Eff(abird-host-agent) ⊂ Eff(abird-host-manager)` is a strict subset** (7 vs 15 entries). `analyze_nodes.py` never folds internal deps and its "subset" check is buggy (see P1-2).                                              |
| E | `nix eval tmp/design-g4/closure-probe.nix`                                                                             | `perMember = {agent 65, wrecking 216, manager 233, bridge 239, hello 0}`, union 367, sum 753, **2.05×**; `closure(manager) == closure(manager ∪ agent) == 233`.                                                                   |

---

## 1. Findings (ranked)

### BLOCKER-1 — E2's peer-derived `core` node breaks the G4 locality contract it claims

**What.** DELTA-LATTICE's `deltaBases` overlay builds `core` from `Decl_core` =
the declaration entries _common to every non-empty member_ (`plan-e2.md` §4.1,
§8). Every `warm_m` has `cargoArtifacts = core` (or a descendant). So `core`'s
drv is an input to every warm node.

**Why it is wrong.** A **member** manifest edit can change `Decl_core` and
therefore change `core`, which invalidates every other member's node. Concrete
trigger at the current 5 members: `core = {anyhow, clap, serde}`; if
`nats-http-bridge` drops `anyhow`, `Decl_core` becomes `{clap, serde}` and the
core closure shrinks; every `warm_m` (agent, manager, wrecking) gets a new drv.
That is a peer edit invalidating unrelated members — exactly what the
requirement forbids. `plan-e2.md` §6 row 2 asserts "core stable" for any
"add/change external dep", which is false for any edit that makes the dep
common/uncommon. E2 §8 knows the core is "derived from the peer set" but does
not connect that to the invalidation matrix. (The default canonical layer — no
core — _is_ G4-correct; the flaw is in the headline "closure-subset forest"
claim.)

**Experiment.** The subset relation is real and common-entry intersections exist
(Exp D, Exp E). The trigger follows directly: any change to the _intersection_
of member maps is by construction not an edit to one member's closure.

**Smallest fix.** Do not peer-derive the core. Either (a) drop it and chain only
along genuine `⊑` edges (agent→manager exists: Exp D), which yields 688/367 =
**1.88×** (E1 S6's number), or (b) declare the core explicitly in root
`[workspace.metadata]` so only a tolerated root edit can change it. Option (b)
keeps the ~1.75× and restores locality.

### P1-1 — Vendor-root fingerprinting silently kills every "per-node pruned vendor + chain/dedup" design

**What.** Exp A confirms Fact A: a cargo `directory` source's `SourceId` embeds
the absolute path, so the same crate bytes at a different vendor root recompile
(`A→B` = 13, even for a symlink farm of the _same_ directories).
`configureCargoVendoredDepsHook.sh` writes `directory = "${cargoVendorDir}"`, so
every node's `cargoVendorDir` store path is the fingerprint.

**Consequences per plan.**

- **E1:** its default per-closure pruned vendors (`vendorOf m`) give distinct
  vendor roots, so `shareVendor = false` means the "chain `manager←agent`"
  saving is **zero**, and the proposed join of an in-repo dependency's
  `memberLayer` is useless (see P1-3). E1 does document this (§6.1) and defaults
  chain off — honest — but its §8.1 cost table lists the 1.88× chain without
  repeating that it requires `shareVendor = true` (global vendor).
- **E2:** v1 correctly keeps the **full vendor** shared by all nodes (§13 Stage
  3 defers pruning), so its 1.75× forest works. But Stage 3 ("per-node pruned
  lock so lock bumps localize", §6 row 8) is **mutually exclusive** with the
  delta forest: pruning the vendor reintroduces distinct roots and the forest
  stops reusing. E2 never states this as a hard conflict (E1 does for its own
  case).
- **E3:** correctly confines chaining to `fused`/`pathComponents` with one scope
  vendor, and correctly makes the default `local` chain-free. E3 is the only
  plan that names the constraint precisely and uses it to choose the default.

**Fix.** Either share one vendor per scope (global lock/vendor invalidation is
explicitly tolerated) or move to stable **per-crate** sources (e.g.
`[patch.crates-io]` entries pointing at crane's per-crate `downloadCargoPackage`
FODs) so each crate's source path is independent of the closure. The latter is
the only route to pruned-vendor chaining; E3 §17.3 raises it and parks it — it
deserves to be the funded direction if dedup is a goal.

### P1-2 — E3's "Fact B" (zero subset relations) is false for the map the design actually uses

**What.** `plan-e3.md` §1.3 claims `agent ⊆ manager` is false at the
declaration-map level ("shlex is in agent and not in manager; tempfile differs
by domain") and concludes "there are zero strict declaration-map subset
relations at 5 members", so it builds the design around meets, not chains.

**Why it is wrong.** E3's own sharing key is `Eff(m) = E(m) ∪ ⋃ E(d)` over
transitive in-repo path deps (§2.2). Folding agent into manager puts agent's
`shlex` and agent's `dev:tempfile` **into `Eff(manager)` as distinct keys**;
manager's own `normal:tempfile` is a separate key. Exp D: `Eff(agent)` (7
entries) is a **strict subset** of `Eff(manager)` (15 entries),
domain-sensitively. The claim is only true for the _own-externals_ map `E`,
which E3 does not use for `classKey`.

**The analysis script is also broken.** `tmp/design-g4/analyze_nodes.py` (a)
computes `classes` and "subset relations" from `ext_map` (own externals, no
folding), and (b) its "pairwise subset relations" loop prints `A subset-of B`
whenever the _common_ entries agree — it never tests `set(A) ⊆ set(B)`. E.g. it
prints `nats-http-bridge subset-of
abird-host-agent: common=3 a=11 b=7`, which
is impossible; and it prints both `A subset-of B` and `B subset-of A` for
several pairs. So E3's "Every pair was checked (analyze_nodes.py)" is not
evidence of anything.

**Impact.** The design's meet-based dedup is still valid; but the claim that
there is no subset-chain lever understates E1's and E2's chain savings, and it
is the stated reason E3 ignores chains. It also means E3's closure sizes in
`analyze_nodes.py` (manager 231, sum 751) are wrong (closure-probe gives
233/753).

**Smallest fix.** Define the planner map once (folded `Eff`), add a real
`set(A) ⊆ set(B) ∧ values equal` test, and correct §1.3; the agent→manager chain
then becomes an available lever.

### P1-3 — E1's in-repo-dep artifact join is a no-op under its own default pruned vendors

**What.** E1 §4.5 sets
`dependencyArtifacts = mkCargoArtifactsJoin { deps = [prefixNode] ++
depLayers; }`
so `memberLayer(m)` can reuse in-repo dependency `d`'s compiled code.
`prefixNode = baseFor(m)` is built against `vendor(m)` (pruned to `closure(m)`);
`depLayers = memberLayerOf d` is built against `vendor(d)` (pruned to
`closure(d)`).

**Why it is wrong.** `vendor(m) ≠ vendor(d)` for a dependent pair
(`lockOf manager` ⊃ `lockOf agent`), so Exp A applies: every unit in `d`'s layer
has a fingerprint tied to `vendor(d)`, and `memberLayer(m)` runs with
`vendor(m)` (`craneCommonAttrs // { cargoVendorDir
= vendorOf m; }`). Cargo
therefore ignores the joined `d`-layer units and recompiles `d` (and `d`'s
externals) under `vendor(m)`. The join materialises a full archive for nothing;
E1's claim "the union of both is exactly what `-p m` needs" is false. The base
already compiled `d`'s externals under `vendor(m)`, so `prefixNode = baseFor(m)`
alone is sufficient and simpler. (Contrast E3 §11: "Reusing the dependency's
memberLayer is only valid in a shared-vendor scope" — E3 gets this right; E2's
v1 full vendor makes its join valid.)

**Fix.** Under pruned vendors, do not join the dependency layer; use
`baseFor(m)` and compile `d`'s real code in `memberLayer(m)`. Only join when the
scope shares one vendor.

### P1-4 — E1's pruned lock can be silently ignored for the member layer (`cargoLockParsed` loses to `cargoLockContents`)

**What.** E1 §4.5 overrides
`craneCommonAttrs // { cargoLockParsed = lockOf m; ... }`. In crane
`mkCargoDerivation.nix:74-78`, `cargoLockContents` takes precedence over
`cargoLockParsed`:
`if args ? cargoLockContents then ... else if args ? cargoLockParsed ...`.
`mkRustDerivation`'s existing `craneCommonAttrs` carries `cargoLockContents`
(the full lock), so if E1 only changes the name to `cargoLockParsed`, the **full
lock** is used while `cargoVendorDir = vendorOf m` is the **pruned** vendor.
Offline builds then fail (full lock references packages absent from the pruned
vendor) or, worse, drift if a shared vendor is used. The base (`buildDepsOnly`
given only source/lock/vendor) is unaffected.

**Fix.** Set `cargoLockContents = <pruned lock text>` (E3's choice) or
`removeAttrs ... ["cargoLockContents" "cargoLock"]` before adding
`cargoLockParsed`. Add an eval test asserting the realised member lock is the
pruned one. Related: E1's `keepLock =
false` applies only to the base; member
`buildSrc` still contains the full `Cargo.lock`, so any lock edit invalidates
all member layers (matrix row acknowledged; allowed by the requirement, but E3's
`lockMode = "omit"` is strictly better for the common "add a dep" case).

### P2-1 — E2/E3 stub folding includes internal deps' **dev**-dependencies (over-priming)

E3's `E(m)`/`Eff(m)` iterates `[dev-dependencies]` of every folded internal dep,
so `Eff(manager)` includes agent's `tempfile` dev closure even though
`cargo build -p manager` never builds agent's dev-deps. E2 §7 explicitly warns
"the generator must not fold `d`'s dev-deps into the node's normal closure"; E3
does not. Cost-only (the member layer re-resolves), but it contradicts E3's §7
"compiles exactly the member's external closure" and inflates every dependent's
node. Fix: fold `normal`+`build` only for internal deps, and add the dependent's
own dev set separately.

### P2-2 — E2's cost projection and E3's 24-member table disagree by ~4× and are unmeasured

E1 projects ~3–6×, E2 ~1.4–2.2×, E3 4.5–7.5× (`local`) / 3–5× (`fused`) at 24
members. All three anchor on 2.05×/1.75×/1.37× at 5 and then extrapolate
different structures. The metric is
`Σ over distinct classes |closure| / |union|`, which depends entirely on the
repo's signature distribution. **The default base policy cannot be chosen from
these numbers.** `analyze_nodes.py`/`cost_model.py` do not fold internal deps
(P1-2) and the "24 manifests" do not exist here, so none of the projections is
evidence. Gate any default flip on a measured 24-member curve (E1 S11 / E2 S7 /
E3 R8), and report per-mode node count as well as compiles.

### P2-3 — Pruned-lock key ignores `source`; multi-version handling is over-approximate

E1 §4.2 / `closure-probe.nix` key packages by `"${name}@@${version}"`, dropping
`source`. Two lock entries with the same name+version but different source
(registry vs git vs alternate registry) collide in `byNv` (`listToAttrs` keeps
one) and would be merged — a latent resolution hazard for repos with git/patch
deps. The repo has none today (Exp C), so it is latent, not active. Also note
the repo's lock has **30 names with 2–3 versions** (e.g. `getrandom`,
`rand_core`, `windows-sys`), so the "vendor has one version per crate" caveat in
`research.md` is wrong in general; Exp C shows the pruned _vendor_ is still
deterministic because it is generated from the pruned lock, but a
**shared/full** vendor + an under-approximated lock can silently re-add a
different semver-compatible version (Exp C with `hashbrown`). With per-closure
pruned vendors the failure is loud (missing package), which is the safe default.
Fix: key by `(name, version, source)`.

### P2-4 — Hidden coupling to `.cargo`, profile, and `cargo generate-lockfile --offline`

- Every filtered base source keeps `.cargo/` (`mkWorkspaceSourcePath`), so any
  `.cargo/config.toml` change (rustflags, target) invalidates **all** bases.
  Repo-global and therefore tolerable, but it is an unlisted global row.
- `nativeBuildInputs`/`buildInputs` needed by externals are a per-closure key
  (E1 `profile`, E3 `nativeProfile`, E2 node identity). Today
  `mkSharedRustDepsBase` takes none, so this is an untested new axis; a wrong
  profile produces a base that either fails or recompiles.
- `checks` run `cargo generate-lockfile --offline` in `preBuild`
  (`pkg-helper.nix:2217`). This **ignores** the installed `Cargo.lock` and
  re-resolves from the vendor. With a pruned, exact vendor it reproduces the
  lock; with a shared/full vendor it is another path to silent re-resolution
  drift. E1/E3/E2 keep this hook; the plans never mention it.

### P2-5 — E3's `classKey` omits the internal path-dep structure and the lock slice

`classKey(m)` is `Eff(m)` + resolver/profile/host/toolchain; it excludes
**which** internal path deps produced `Eff(m)` and excludes the lock. Two
members with equal `Eff` but different internal edges can share one node while
needing different path-package entries in the pruned lock. Cargo can re-add path
entries offline, so this is a corner case, but the shared node's lock is the
representative's and the "same vendor for equal maps" proof needs the path set
too. Fix: include the closure's internal member-name set in the key (cheap, pure
eval).

### P2-6 — E1's K1 base is `.rs` add/remove sensitive; avoidable, not required

Confirmed by reading crane `mkDummySrc.nix:231-237` (`builtins.readDir` on
`src/`, `src/bin`): adding/removing `lib.rs`/`main.rs`/`bin/*` changes the dummy
script text and therefore `base(m)`. Content edits and metadata-only Cargo.toml
edits do not (Exp E / research §0). It is local to `{m} ∪ Dep(m)`, so it does
not violate the stated requirement (which is about Cargo.toml edits), but it is
a self-inflicted rebuild that E2's and E3's generated manifests/stubs eliminate
by construction. E1's S9 (manifest-only base) is the right hardening and should
be considered part of K1, not deferred.

### NOTE-1 — Equality-dedup does **not** couple members (content-keyed nodes)

A worry that sharing a base between members with identical `Eff` couples their
rebuilds is **not** a problem: both E2 canonical and E3 `local` build the node
from the map content, so editing member A creates a _new_ node and leaves the
old node (used by B) byte-identical. This is a point in favour of E2 (canonical)
and E3 (`local`). The peer-derived `core` (B1) is the exception precisely
because it is not content-keyed to one member.

### NOTE-2 — Pruned-vendor downloads are still deduped by Nix

`vendorMultipleCargoDeps` emits per-crate `downloadCargoPackage` FODs; identical
crates in different per-closure vendor dirs are the same FODs, so per-closure
vendoring duplicates the small symlink-directory derivation, not the 347 MB of
crate contents. E1's "vendor(agent) 64 vs 367" is a directory-size statement,
not a store/network one.

### NOTE-3 — Mirror/G10 root-manifest tension (E1/E3)

Both E1 §9 and E3 §10 claim a layout-preserving mirror yields the same base/node
drv. That requires the mirror to carry the **original** root `Cargo.toml` (full
`members` list, or at least identical bytes), while a self-contained mirror
usable by non-Nix cargo needs the `members` list rewritten. The filtered base
source hashes the root `Cargo.toml`, so the two requirements conflict unless the
mirror ships both a pristine manifest (for Nix) and a rewritten one (for
humans). The claim is plausible but not free; state the extra artifact.

---

## 2. What each plan gets right

- **All three** correctly refuse IFD: pure `fromTOML`/`readFile` planners and
  crane `cargoLockParsed`/`cargoLockContents` (no lock serialiser derivation
  read back). E1's parsed-lock route and E3's parsed-lock/vendor route both
  avoid the `fromTOML`→derivation round-trip. Verified `vendorCargoDeps` accepts
  `cargoLockParsed` (crane `vendorCargoDeps.nix:46`).
- **Correctness model is sound where it matters:** every plan keeps the _real_
  member source and `-p m` resolution for the deployed artifact, using the
  base/node purely as a cache, so no plan can widen a member's actual
  resolution. Pruned locks are `--offline`-safe (Exp C) and cargo never moved a
  version in any experiment.
- **E1:** honestly names the vendor-root blocker and defaults chain off; exposes
  `shareVendor`/`basePolicy` knobs; `closureDirs`/`-p m` exactness argument is
  correct; the 2.05× figure is exactly reproduced (Exp E); the closure-subset
  chain `manager←agent` is real (Exp D) and its 1.88× is arithmetically right
  once vendor is shared.
- **E2:** the "delta artifacts, not delta sources" distinction is the single
  most important correctness insight for layering; the `⊑` parent rule is sound
  and conservative; canonical per-node bases are a complete, simple, G4-correct
  default; the 1.75× forest arithmetic is right (≈638/367) and my Exp B confirms
  the delta only compiles the child's extra units when the vendor is shared; it
  honestly flags that delta loses mirror base-drv sharing.
- **E3:** the only plan that (a) states Fact A as a hard design constraint and
  derives its default from it, (b) gets the internal-dep/vendor interaction
  right, (c) excludes the root lock from sources (`lockMode = "omit"`) so the
  common "add a dep" edit localises, and (d) models `activationSensitive`
  members as `solo` so pure-eval feature blindness can only cost recompiles,
  never semantics. Its `local` invalidation matrix (content-keyed class nodes,
  equality dedup) is correct.

---

## 3. Bottom line

The G4 requirement (member-manifest locality, no IFD, no widening, G10/G11) is
best met by **E3 `local`** or **E2 canonical** (both content-keyed per-member
bases). E1's per-closure `buildDepsOnly` bases also satisfy it but carry an
unnecessary ineffective join (P1-3), a lock-precedence footgun (P1-4), and
`mkDummySrc` `.rs`-structure sensitivity (P2-6). All dedup beyond per-member
duplication (E1 chain, E2 forest/core, E3 fused) is blocked or degraded by the
vendor-root fingerprint (P1-1) and, for E2, by the peer-derived core (B1). The
cheapest correct wins are: fix E2's core to be root-declared (or drop it), fix
E1's join/precedence/keepLock, and fund per-crate source pinning if dedup is
actually wanted.
