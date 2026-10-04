# G4 researcher lane — per-base closure invalidation, canonical locks, incremental inheritance

Date: 2026-09 (council G4). Repo read-only; experiments under `tmp/design-g4/`.
Env: cargo 1.95.0 / rustc 1.95.0, nix 2.34.8, crane rev
`7rradzysxg41b2yx7qnh2f2bw73py192`; network **available** (curl/doc fetches
succeeded). Method: read landed L + crane internals; then real cargo experiments
(subset source filtering, lock pruning, stub workspaces, pruned vendor) and a
lock-derived cost model.

## 0. Baseline facts (why G4 exists)

- The one base is built from **all** member manifests: `rustWorkspaceMembers`
  (`lib/flake/pkg-helper.nix:142`) → `mkRustWorkspaceSource` (`:167`) →
  `mkSharedRustDepsBase` (`:179`), `cargoExtraArgs = "--offline --workspace"`.
- `buildDepsOnly` hard-sets `cargoArtifacts = null`
  (`.../lib/buildDepsOnly.nix:64`); every `memberLayer` names that base
  (`pkg-helper.nix:2383`), so any base change re-runs every member layer from
  scratch.
- Crane already launders manifests: `mkDummySrc` keeps only dependency-relevant
  fields via `cleanCargoToml` (`.../lib/mkDummySrc.nix:147`,
  `.../lib/filters/cargoTomlConservative.nix`). So
  `description`/`lints`/`badges` never invalidate a base; dependency fields do.
- Base is **`.rs`-content invariant** but **`.rs`-structure sensitive**:
  `mkDummySrc` `readDir`s `src/`, `src/bin` (`mkDummySrc.nix:231-237`), so
  add/remove of `lib.rs`/`main.rs`/`bin/*` can change the dummy (matches S7).

## 1. Per-base closure invalidation: the drv inputs

**Finding.** _A base's transitive inputs must equal a manifest projection of its
own resolved external closure — never another member's raw manifest._ Two
constructions satisfy this.

**(a) Filtered-subset base (smallest delta from L/M).** Build from
`mkWorkspaceSourcePath { selectedDirs = {m} ∪ ancestors(m); }` and rewrite root
`members` (`cargoWorkspacePrePatch`, `pkg-helper.nix:235`). Verified:
`tmp/design-g4/filter-probe.nix` — the agent-only subset source contains only
`./Cargo.toml`, `./Cargo.lock`, `./pkgs/tools/abird-host-agent/Cargo.toml`; no
other member manifest (store `…-probe-subset-source`). The root `members` text
is global, but the prePatch awk rewrites it before cargo runs. Caveat: an
ancestor `p` (needed for `path = "../p"`) is also dummy-compiled in the base,
duplicating its externals — dependents-direction, so G4-safe but wasteful.

**(b) Generated deps-workspace / stub base (exact).** Generate a synthetic
workspace with one member `stub-m`: `stub-m/Cargo.toml` declares exactly m's
**external** direct deps (normal+build+dev, `workspace = true` resolved to
concrete version/features); each direct in-repo `path` dep becomes a cheap empty
stub. No real member manifest is an input. This is design F's `depsSrc` at
member granularity. Verified: `tmp/design-g4/stub-agent/` ran
`cargo metadata --offline` and `cargo check --offline` against the vendor dir
and resolved the **same 65 packages/versions** as the real agent workspace (zero
version mismatch).

**Drv inputs of a base:** (1) the filtered/generated source path: root manifest
(with `[workspace.dependencies]`), `Cargo.lock`, `.cargo/`, selected member
manifest(s) — never their `.rs` contents; (2) `cargoVendorDir` (full or pruned,
§2); (3) toolchain/stdenv/platform/env + `--offline` selection; (4)
pname/version and _canonical_ (per-base, not per-member) `nativeBuildInputs`.
`mkCargoDerivation` adds constant hooks.

**Confidence:** high. **Implication:** (b) is the only construction whose
invalidation key is exactly the member's external closure; (a) is simpler and
keeps L's `--offline -p` semantics but keys on ancestors' manifests.

## 2. Canonical / pruned lock

**Finding.** A lock can be pruned to a closure and built `--offline` against a
vendor dir, deterministically, **provided `--locked` is not used**. Pruning does
not change versions. Cargo needs every transitively-needed package present with
source+checksum; the `directory` vendor pins versions. Under-approximation is
repairable offline from the vendor; over-approximation is dropped.

Evidence (`tmp/design-g4/`):

- `prune_lock.py` computes the precise reachable lock closure.
- `subset-agent/` (agent-only, pruned lock): `--offline --locked` **fails**
  ("cannot update the lock file... remove --locked"); without `--locked` cargo
  drops the over-approximated package `rand_core` — **zero version changes**.
  The cargo-produced exact lock then passes `--locked`.
- `subset-minlock/` (lock deleted) + vendor dir: cargo resolves 65 packages
  offline with **no version drift** vs the exact lock, because the directory
  source exposes only vendored versions.
- `subset-fulllock/`: full lock + subset source works `--offline`; cargo
  rewrites the lock to the 65-package closure at build time.
- `vendor-agent/`: `cargo vendor --offline` from the 65-package lock yielded 64
  crates; `cargo check --offline` succeeded.

**Confidence:** high for this repo/toolchain (one version per crate in vendor).
Caveat: multiple vendored versions would let an unlocked subset re-resolution
pick a different compatible version; keep a lock to avoid that. **Implication:**
design M's `--offline` (not `--locked`) is correct. For O5 prune the lock and
vendor per base; the vendor, not `--locked`, is the version pin.

## 3. Incremental base inheritance (O6)

**Finding.** Feasible, but only via crane `cargoArtifacts` inheritance on
`mkCargoDerivation`; `buildDepsOnly` can never inherit (`buildDepsOnly.nix:64`).
`installCargoArtifactsHook.sh` writes a delta archive and symlinks
`target.tar.zst.prev` to the parent (`:27`); `inheritCargoArtifactsHook.sh`
follows `.prev` recursively (`:21-23`), so a child compiles only fingerprint-
changed units. To express "inherit the previous base" **without IFD**, the
parent must be an explicit drv input:

1. **Intra-plan chain (recommended):** order bases by closure inclusion;
   base(child) = `mkCargoDerivation { cargoArtifacts = base(parent); … }` with
   parent the nearest closure-subset ancestor in the _current_ plan. Pure eval,
   no state; a parent change re-runs descendants but cargo reuses fingerprints.
2. **Cross-commit pinned base:** reference a fixed store path (flake input /
   `builtins.storePath` / hashed FOD nar). Pure, IFD-free, but requires
   publishing+pinning.

There is no pure way to ask "whatever the previous base was": Nix is a function
of inputs, not history. O6 must materialize the parent.

**Confidence:** high (crane source) / medium for cross-commit cleanliness.
**Implication:** O6 pays only along a closure-inclusion chain (current repo:
`agent ⊆ manager`, saving 65 units). Disjoint/near-disjoint closures (`bridge`
vs `wrecking-ball`: 193 shared / 262 union, neither a subset) cannot
chain-share; that needs a join/union, which reintroduces a global key. Do
F-style chains _inside_ exact per-member bases; do not promise cross-commit
inheritance in v1.

## 4. Exactness rule for sharing

**Finding.** Two members may share one base **iff their base inputs are
byte-identical**: same resolved external declaration map + lock/vendor + profile

- toolchain + target + env. Then cargo's resolution/feature unification is a
  pure function of those inputs, so hash-consing yields `drvPath` equality and
  zero widening.

- **Sufficient pure-eval test (no IFD):** equality of the member's _resolved
  direct declaration map_ — for `[dependencies]`, `[build-dependencies]`,
  `[dev-dependencies]`, `[target.<cfg>.*]`: name → (version req, `features`,
  `default-features`, `optional`), with `workspace = true` substituted from root
  `[workspace.dependencies]` — plus lock hash, profile, target, toolchain. Sound
  (identical decls + lock ⇒ identical units) but not complete (different decls
  can resolve to the same units).
- **Pure eval knows:** manifests + `Cargo.lock` (names, versions, sources,
  checksums, features-as-written, cfg tables). **Only cargo knows:** effective
  feature unification/optional activation, `cfg(target)` evaluation, per-unit
  features. `cargo metadata` cannot represent per-unit feature relationships;
  `cargo --unit-graph -Z unstable-options` does (unstable book, §6).

**Confidence:** high. **Implication:** key sharing on a **hash of the resolved
declaration map** (+ profile/target/toolchain), not raw manifest bytes and not
cargo features. Conservative: identical maps share exactly; near-identical maps
(the nats pair) do not, and pay duplication. That is the price of no-IFD
exactness.

## 5. Cost model

**Finding.** Reproduced the measured per-member external closures exactly:
`{hello-rust 0, agent 65, wrecking-ball 216, manager 233, bridge 239}`, union
367 package-instances, **Σ = 753, duplication 753/367 = 2.052×**
(`tmp/design-g4/cost_model.py`). All 5 members have **distinct direct-decl
signatures** (5 bases) and distinct package closures. Structure:
`agent ⊆ manager` (65 shared, chain-savable); `wrecking-ball ∩ bridge = 193`
(Jaccard 0.74) but neither is a subset, so one base cannot serve both without a
union (which widens).

**Projection to 24.** The right metric is
`Σ over distinct signatures
|closure(sig)| / |union|`, not member count. With
`k` members sharing an ecosystem but with per-member feature divergence, each
gets its own base and pulls ~E externals, so the factor approaches `k` for that
ecosystem. Anchor: 2.05× at 5. A 24-member repo of 4–6 ecosystems with
mostly-distinct signatures is plausibly ~3–6×; recompute from the real manifests
(the script generalizes). O2 (identical signatures) and O6 (chain inheritance)
are the only levers that reduce it without widening; each member's own base is
the floor.

**Confidence:** high for 5; medium for the projection. **Implication:** budget
per-base compile cost and gate per-base defaults on the measured 24 curve (S11).

## 6. Prior art

Network available (crane.dev, doc.rust-lang.org, raw.githubusercontent.com all
200).

- **crane** — layered `cargoArtifacts` + `.prev` delta archives +
  `buildDepsOnly`; "Never build twice thanks to incremental artifact caching".
  The mechanism G4 extends to per-closure bases.
- **cargo2nix / crate2nix** — generate _one Nix derivation per crate_ from
  `Cargo.lock` (`cargo metadata`), selling "precise, incremental rebuilds / only
  rebuild changed crates"; crate2nix offers manual (no-IFD) and auto (IFD)
  strategies. This is O7 and the generated-data + drift-gate pattern design M
  already uses. (`github.com/cargo2nix/cargo2nix`,
  `github.com/nix-community/crate2nix`.)
- **naersk** — parses `Cargo.lock` in Nix, deps+app in two derivations, relies
  on cargo fingerprint incrementality; no per-dependency Nix factoring.
- **cargo itself** — authoritative unit graph
  (`--unit-graph -Z unstable-options`) with per-unit features and content
  fingerprints (Cargo Book "Build Cache"). Explains why inheritance works and
  why `cargo metadata` cannot drive feature-exact sharing.
- **sccache** (non-Nix) — object-level reuse; not sandbox-pure.

**Confidence:** high. **Implication:** per-unit Nix graphs are prior art but
need generated files/IFD and re-implement resolution; within no-IFD + mirror
identity, crane layering + generated deps-workspaces + a resolved-decl signature
hash is the closest valid pattern.

## 7. Consolidated implications

1. Exact locality needs (a) a subset source keyed only on the member(+ancestors)
   manifest, or (b) a generated stub deps-workspace with no real manifests; (b)
   is exact and extends design F/M, (a) is the cheapest step.
2. A base shared across path-connected peers **always widens** for the
   non-dependent direction; replace component sharing with per-member bases
   joined by `mkCargoArtifactsJoin` (`pkg-helper.nix:198`) over
   `{base_m} ∪ {memberLayer(p)}` for `p ∈ internalDeps(m)`.
3. Keep `--offline`, drop `--locked` for bases; prune+vendor per base for O5.
4. Share on equality of the resolved direct-declaration hash (+
   lock/profile/target/toolchain).
5. O6 = intra-plan closure-inclusion chain via `mkCargoDerivation` +
   `cargoArtifacts`; `buildDepsOnly` cannot inherit; no cross-commit claim.
6. Recompute `Σ|closure|/|union|` at 24; anchor 2.05× at 5.

### Verified artifacts (`tmp/design-g4/`)

`filter-probe.nix`; `prune_lock.py`; `subset-agent/`, `subset-minlock/`,
`subset-fulllock/`; `stub-agent/`; `vendor-agent/`; `cost_model.py`.

### Residual risks / not proven

- Feature-exact sharing is undecidable in pure eval; the decl-map rule is sound
  but conservative.
- `--locked` canonical locks need cargo's own resolution; hand-pruned is only
  `--offline`-safe.
- The exact-locality stub generator (features/default-features/path stubs, cfg
  tables) is unbuilt; only a no-path-dep member was tested.
- 24-member cost is projected, not measured.
