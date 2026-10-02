# Critique of Plan C — REWEAVE

Scope: attack `tmp/design-f/plan-c.md` against the real code
(`lib/flake/pkg-helper.nix`, crane rev in
`/nix/store/7rradzysxg41b2yx7qnh2f2bw73py192-source`) and cargo 1.95. Scratch
experiments under `tmp/design-f/{attack,opt,pathtest,mv,unused}`. Verdict: the
central _idea_ (force the union by rewriting the member's own dependency table)
is sound and does remove the direct-declaration residual, but the plan as
written contains two build-breaking defects, a false exactness theorem, and a
partial Cargo resolver it claims not to have. It is **not** landable as written
and is not clearly simpler than Plan A.

---

## BLOCKER

### B1. `canonicalManifest` copies the shard's **internal path deps** into every member

**What.** §4.5 defines
`canonicalManifest(m,S) = (memberManifest m) // { dependencies = table u "dependencies" "."; … }`
with `u = U(S)`, and §2.1/§4.3 put `path` entries into `decls`/`U`. So every
member gets every shard-mate's path deps. A member's source tree is built by
`mkCargoWorkspaceSource { projectDir; deps }` (`pkg-helper.nix:102`) and
contains only `[projectDir] ++ resolvedDeps`; the other members' directories are
absent.

**Why (evidence).** `tmp/design-f/pathtest`: `m1` path-depends on `libn`, `m2`
does not. Building `m2`'s filtered tree (root members rewritten to `m2`,
manifest carrying the union's `../libn`) gives:
`failed to read /tmp/m2tree/libn/Cargo.toml: No such file or directory`. In this
repo `abird-host-manager` is the only member with an internal path dep
(`abird-host-agent`), so `U(M)` contains it and **four of the five members**
(bridge, agent, wrecking-ball, hello-rust) get a dangling path dep.

The tempting fix — include all shard members' dirs in every member source —
breaks `.rs` locality, because `mkWorkspaceSourcePath` keeps selected dirs _in
full_ (including `*.rs`). Then a `.rs` edit to any member changes every member's
`buildSrc` hash. The plan's "`.rs` edits stay local" then fails.

**Smallest correct fix.** Make `U(S)` external-only: exclude `path` entries from
the merged tables. Keep each member's own path deps verbatim from
`memberManifest m`. Then a member's tree is exactly its own internal closure,
and the external feature union is unaffected (externals of path deps are
compiled and reused through the path dep's own member layer). Document that
`decls` for the union means _external_ declarations.

---

### B2. Sharded base (the recommended REWEAVE-P / C2) leaves the root `[workspace].members` unfiltered

**What.** §5.3 builds a shard base as
`mkRustWorkspaceSourceFor { members = S.memberDirs }` →
`mkWorkspaceSourcePath { selectedDirs = S.memberDirs }`, then
`buildDepsOnly { dummySrc = mkDummySrc { src = shardSource; }; cargoExtraArgs = "--offline --workspace"; }`.
`mkWorkspaceSourcePath` keeps the **root** `Cargo.toml` unmodified
(`lib/flake/pkg-helper.nix:67-96`), and crane's `cleanCargoToml`
(`filters/cargoTomlConservative.nix`) keeps `[workspace].members`. The base has
no `prePatch`/`cargoWorkspacePrePatch` (only member builds do). So `--workspace`
tries to load members that were filtered out of the source.

**Why (evidence).** `tmp/design-f/pathtest` reproduced the first half of this
exactly: after filtering the tree to `m2` only but leaving
`members = ["m1","m2","libn"]`, cargo fails with
`failed to read …/m1/Cargo.toml`. C1 (one global shard = all members) dodges it,
but C1 is the degenerate mode the plan says is only safe when polarity is
uniform; the recommended default REWEAVE-P/C2 hits it.

**Smallest correct fix.** Reuse the existing root-member rewrite for the base
too: pass the same `awk`-based `[workspace].members` rewrite
(`cargoWorkspacePrePatch`, `pkg-helper.nix:235`) as `prePatch` to
`buildDepsOnly`, or generate a canonical root manifest for the shard. This is a
~5-line change; without it C2 cannot build.

---

## P1

### P1-1. The exactness theorem is false for member `[features]` activations of externals → residual returns

**What.** §2.2/§6.1 claim the base's `--workspace` resolution and the rewritten
member's `-p m` resolution are the same because both have "the same root
requirement table". They are not the same table: the base selects _all shard
members as roots_, so a member's `[features] default = ["dep:foo"]` or
`"pkg/feat"` entry activates externals in the base. The rewrite copies only
**dependency declarations**, not other members' feature tables, so member `m'`
(which has no `foo` optional dep and no `pkg/feat` entry) misses those
activations. Result: externals recompile — the exact residual REWEAVE is
supposed to remove.

**Why (evidence).** `tmp/design-f/attack`: `manager` declares
`libt = { default-features = false, features = ["std"] }` and
`[features] default = ["libt/extra"]`; `bridge` depends on `libt` with no extras
(reached both directly and transitively via `liba`). Base
(`-p manager -p bridge`, equivalent selection to `--workspace`) compiles `libt`
with `--cfg 'feature="extra"' --cfg 'feature="std"'`. Rewriting `bridge` to the
declaration union (libt `std`, no `extra`) and building `-p bridge` recompiles
`libt` with only `feature="std"` — libt is **not** reused. `extra` is in no
dependency declaration; it exists only in manager's feature table. In this repo
members currently have no `[features]` tables, so today's headline happens to
hold, but it is not a property of the mechanism.

**Smallest correct fix.** The union must be of _resolved, activated_ features,
not declared features: for each external, compute the feature closure the base
activates (including `pkg/feat` entries reachable from each member's default +
enabled features) and emit that set on the member's direct declaration. That is
a real (small) resolver step. Cheaper conservative alternative: if a member has
any non-trivial `[features]` table that references an external, put it in its
own REWEAVE-S shard.

### P1-2. `optional = AND` + preserved `[features]` produces a hard manifest parse error, not a cache miss

**What.** §4.3 sets `optional = (a.optional or false) && (b.optional or false)`
and §4.5 preserves member `[features]` verbatim. If member A has
`libo = { optional = true }` with `default = ["dep:libo"]`, and shard-mate B
declares `libo` non-optional, `U(S)` makes `libo` non-optional while A's
`[features]` still says `dep:libo`. Cargo rejects the whole manifest.

**Why (evidence).** `tmp/design-f/opt`:
`feature 'default' includes 'dep:libo', but 'libo' is not an optional dependency`.
The failure is at manifest parse time — `cargo build -p A` cannot even start.
The plan files this under "loud compile error or cache miss"; it is neither a
cache miss nor a nice compile error, it is an unbuildable manifest, and the pure
planner cannot see it (§6.3 admits `[features]` merging is "partial" but offers
no detection).

**Smallest correct fix.** Do not blindly AND `optional`. Track whether any
member's `[features]` references `dep:X`; if `X` becomes non-optional, rewrite
that feature entry from `dep:X` to `X` (and validate at eval, throwing rather
than emitting an invalid manifest). Alternatively shard members with
`dep:`-gated externals into REWEAVE-S.

### P1-3. Churn-locality claim is false in this repo (uniform polarity ⇒ one shard ⇒ global rebuilds)

**What.** §1/§11/V6 claim a dependency-manifest change rebuilds "only the
affected shard base and its dependents" and (C2) "only its shard base". But
REWEAVE-P's shard key is the polarity vector; this repo's polarity is uniform,
so REWEAVE-P collapses to **one** shard.
`memberLayer.cargoArtifacts = dependencyArtifacts` →
`prefixNode = sharedDepsBase` (`pkg-helper.nix:2383-2411`), and
`sharedDepsBase`'s dummy input embeds the eval-read member manifests (crane
reads/cleans `Cargo.toml` at eval in `mkDummySrc.nix`). So any member manifest
edit changes `U(S)` and `sharedDepsBase`, which re-runs **every** member layer.
That is Plan A's P2-2 exactly, not a C2 improvement.

**Smallest correct fix.** Be honest: in the uniform-polarity case C1/C2 are one
base and manifest churn is global. If local manifest churn is a requirement,
shard on the member's own (external) manifest signature (REWEAVE-S), or exclude
the changed member from `U(S)` when its externals are unchanged (needs a
per-member demand key, i.e. Plan B).

---

## P2

### P2-1. Polarity sharding is declaration-level only; transitive conflicts still widen

Concrete scenario: A and B both declare `reqwest {default-features=false}` (same
vector), and B also declares `Q`, where `Q` depends on `reqwest` with default
features. Same shard; `U(S)` contains `Q`; the base and A' both resolve
`reqwest` with defaults on. A is widened against its explicit
`default-features=false`. There is no residual (base and member agree), but
§6.4's "polarity-exact at the declaration level … no shard ever flips a
polarity" is misleading: the _effective_ polarity is flipped via a transitive
path the vector cannot see. The mitigation (a build-time
`cargo tree -e features` detector) is outside the pure planner and would have to
trigger a shard _split_ at eval, which is not described. Fix: compute resolved
polarity from the lock closure, or drop the "polarity-exact" claim and label
widening as the accepted policy.

### P2-2. Emitter keys by version-_requirement string_, not resolved version

§4.3 keys entries by `(domain, target, package, version)` where `version` is the
declared requirement. Two members can write different requirement strings that
resolve to the same locked version (`"1"` vs `"1.0"`, or a member's
`serde = "1.0.200"` beside `workspace = true`). The emitter then emits the same
package twice under two keys → cargo
`depends on crate X multiple times with different names`. The plan's own §4.5
bullet warns about exactly this error but does not close it. Also, "the union's
P entry is emitted under the member's existing key K" is unspecified when the
member declares one of several version families — assigning the wrong family to
`K` breaks the member's source. Fix: re-key by resolved `(name, version)` from
`Cargo.lock`, dedupe, map the member's resolved version to its declared key,
emit others under `name_<major>`. (`tmp/design-f/mv` confirms two different
versions under different keys are accepted.)

### P2-3. Shard closure under internal path deps is an unchecked invariant

§2.3 asserts shards are closed under internal path deps, but the partition
functions (§2.4, polarity-vector/constant/per-member) can split `m` from its
path dep `n` when their polarity vectors differ. Then `m`'s union misses nothing
external but `n`'s member layer chains a **different** base, and `m`'s build of
`n` can also recompile `n` if `m` requests different features on `n` than `n`'s
own layer used. Fix: take connected components over internal path-dep edges
first; a shard is a union of components. Also, internal path-dep feature
requests must be forced like externals (currently §4.3 "kept verbatim"),
otherwise manager→agent-style edges can still recompile.

### P2-4. Optional canonical base clobbers crane's build-script stub

§5.3's `extraDummyScript` installs a whole generated `Cargo.toml` over crane's
cleaned manifest, which had `package.build = dummyBuildScript` written by
`mkDummySrc` (`mkDummySrc.nix`) so build-dependencies are primed. The generated
manifest comes from the real member manifest and usually has no such override;
the plan's fallback, `writeText "dummy.rs" "fn main() {}"`, is not crane's
`dummyBuild.rs` (no no_std/`main` handling). Either build-deps silently stop
being primed (reintroducing a residual) or the base fails. Fix: don't install a
whole manifest; splice only the dependency tables into the already-cleaned TOML
via `cleanCargoTomlFilter`/`recursiveUpdate`, preserving `package.build`.

---

## NOTE

- **Complexity contradicts "no resolver reimplementation".** §2.2 claims no
  resolver is needed, but §4 is a partial Cargo resolver: `workspace=true`
  override resolution, multi-version keying, target tables, renames, `optional`
  AND, feature-table merging. It is the same class of work as Plan A's planner,
  with the two correctness gaps above. "maintenance-light" is overstated.
- **Degradation holes are total, not partial.** Globs in `[workspace].members`
  and `projectDir = "."` disable sharing for the _whole repo_ (falls back to L).
  A 24-member workspace commonly uses globs; that is a large latent loss of the
  plan's value.
- **`hello-rust` and unused deps.** `hello-rust` (empty closure) gets the entire
  union as direct deps; harmless (no `unused_crate_dependencies` warning by
  default, confirmed in `tmp/design-f/unused`) but contradicts "no widening".
  Adding deps does not change externals' fingerprints; the member's own unit
  recompiles as expected.
- **Lock/vendor posture is sound.** `U(S)` ⊆ the sum of members' resolved
  features, so no new packages; one `vendorCargoDeps`; `--offline` additive edge
  (plan spike 3; my reproduction of `extra` shows the lock stays consistent).
  Keep V4: assert resolved versions unchanged, since `--offline` can silently
  downgrade if a pin is wrong.
- **The failure detector is a genuine improvement** and directly catches
  P1-1/P1-3 as a `nix flake check` derivation.
- **Plan-vs-plan comparison is slightly strawmanned.** Plan A can be per-member
  (`-p m -p aggregate(m)`) and per-shard too, which also handles polarity; Plan
  A's real cost is the synthetic lock entry, not a fixed global union.

---

## What Plan C gets right

1. **It does fix the concrete transitive residual for externally declared
   packages.** `sha2` (reached by `nats-http-bridge` via
   `async-nats → nkeys → ed25519-dalek`) _is_ directly declared by
   `abird-host-manager`, so `U(S)` contains it and the rewrite forces the same
   features into bridge. `tmp/design-f/attack` shows the analogous case: after
   adding `libt {features=["std"]}` (a shard-mate's direct decl) to `bridge`,
   only `bridge` recompiled; `libt`/`liba` were reused. The rewrite is a real
   union-forcing mechanism.
2. **No IFD, unchanged public API.** The planner reads `Cargo.toml`/`Cargo.lock`
   at eval; `writeTOML` is a build-time-only derivation;
   `mkRustDerivation { projectDir; … }` is untouched.
3. **`.rs` locality holds.** crane's `mkDummySrc` filters the base input to
   `.cargo/**` + `Cargo.lock` + eval-read manifests (`mkDummySrc.nix`), so
   `*.rs` edits do not change the base; `mkWorkspaceSourcePath`'s
   `cargo-workspace-source` name preserves the unpack path required for
   fingerprint reuse (fact 2).
4. **No new lock package / no synthetic crate**, and the `--offline` additive
   edge works.
5. **The shard-key continuum (A↔C↔B) is a useful framing**, and the
   zero-external- `Compiling` assertion is a good, testable gate.

## Reproduce

```
tmp/design-f/attack   # transitive/direct union works; feature-table activation residual
tmp/design-f/opt      # optional dep + dep: gate => hard manifest error
tmp/design-f/pathtest # missing internal path dep; unfiltered root members
tmp/design-f/mv       # two versions under distinct keys compile
tmp/design-f/unused   # unused dep: no warning, no external recompile
```

All with `cargo 1.95.0`, `--offline`.
