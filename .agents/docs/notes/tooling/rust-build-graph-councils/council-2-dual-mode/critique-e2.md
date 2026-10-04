# Critique E2 "FACET" — council 2 (harsh)

Repo `0711cc31`, read-only; scratch `/tmp/facet-*`. Read
`tmp/design-f2/plan-e2.md` in full, `tmp/design-f2/research.md`,
`lib/flake/pkg-helper.nix`, `lib/flake/{packages,root,default}.nix`,
`lib/flake/stack/package.nix`, the 5 member `Cargo.toml`s, and ran cargo/nix
experiments (documented inline).

---

## BLOCKER

### B1. The G10 mirror layout / `memberDir` contract is internally contradictory and the generator omits member sources

**What.** The headline property is "`componentSource` is byte-identical in
monorepo and mirror" (§4), from which `component.key`, `pname`, and the drv
follow. But the plan gives two incompatible layouts and an incomplete file set:

- §2.2: `self.memberDir = "pkgs/tools/abird-host-agent"; # "." in a mirror`
- §4: "The mirror preserves the monorepo-relative layout (`pkgs/tools/...`), so
  `component.members` strings are identical across modes."
- §11.1 `mkMirrorFiles` emits only `definition.nix`, `Cargo.toml`, `Cargo.lock`,
  `flake.nix`, `flake.lock`, optional `.cargo/config.toml` — **no `pkgs/**`
  member source trees at all.** **Why it breaks.** The only real multi-crate
  component is agent+manager, coupled by
  `pkgs/tools/abird-host-manager/Cargo.toml:9 abird-host-agent = { path = "../abird-host-agent" }`.
  If the mirror flattens (`memberDir="."`), the sibling path dep no longer
  resolves and `component.members` becomes something like
  `["abird-host-agent","abird-host-manager"]` instead of `["pkgs/tools/..."]`;
  `component.key`/`pname`/source differ ⇒ `facet-mirror-drv-eq` is unachievable.
  If it preserves the layout, `memberDir` cannot be `"."` and `mkMirrorFiles` is
  missing every member dir. Either way the plan is not "implementation-ready"
  for G10's central claim. **Smallest fix.** Declare the mirror layout to be
  monorepo-relative (`pkgs/<...>`), set `memberDir` to the true repo-relative
  path, add every `component.members` directory to `mkMirrorFiles`, and assert
  `component.key` and the `facet-members`/`cargo-workspace-source` store paths
  equal in `facet-mirror-fresh`.

### B2. `--locked` component base fails as written; spike S2 is false

**What.** §5.1/§9 specify the base as `--locked --offline --workspace` with
`cargoLockContents = definition.lock.contents` (the **full** monorepo lock).
§7.2/S2 claim "lock unchanged". The member uses `--offline` (no `--locked`).
**Experiment.** `/tmp/facet-mgr2`: full `Cargo.lock` + component root
`members=["pkgs/tools/abird-host-agent","pkgs/tools/abird-host-manager"]`:

```console
cargo check --locked --offline -p abird-host-manager      → FAIL
cargo check --locked --offline --workspace                → FAIL
error: cannot update the lock file ... because --locked was passed
```

Reason: pruning members removes the lock entries for the absent workspace
members, so cargo must rewrite the lock and refuses under `--locked`.
(`cargo metadata --locked` passes because it does not need to write the lock;
`check`/`build` do not.) **Secondary finding.** Without `--locked`, cargo
re-resolves against the local cache: `cargo generate-lockfile --offline` changed
`anyhow 1.0.102→1.0.104`, `clap 4.6.1→4.6.5`, `serde 1.0.228→1.0.229`,
`zeroize 1.8.2→1.9.0`. In a real build this is prevented only by
`cargoVendorDir = vendorCargoDeps { cargoLockContents }` pinning the exact
crates; the plan treats the lock as the resolution source but never names the
vendor dir as the pin. **Smallest fix.** Use `--offline --workspace` on the base
(the plan's own §9 fallback), state that `vendorCargoDeps { cargoLockContents }`
is the version pin, and replace S2 with a lock-frozen/`cargo metadata` gate.
Generate a component-filtered lock if `--locked` fidelity is required.

---

## P1

### P1-1. Union-base injection re-monorepo-keys adoption; the drv-equality gate tests a non-default mode

§7.1 compares `standalone(componentBase)` vs
`monorepoComponentMode(componentBase)`, but the shipped default is the **union**
base (§0/§8), and §17.1 concedes union is not artifact-identical. Mode B passes
`base = unionBase` — a derivation built from the monorepo's whole-repo
manifest/source — into the external declaration. The external's "standalone" drv
therefore depends on monorepo-only inputs, i.e. the G10 independence claim is
lost precisely when sharing is used, and `facet-union-fresh` is a heuristic, not
an equivalence proof for the default build. _Concede:_ the semantic argument
(§7.2) is basically sound — cargo fingerprints include features, so a mismatched
union-base unit is rebuilt, not substituted; the member binary is a function of
`R(m)`. But "mirror drv == in-repo drv" is true only for a configuration nobody
ships. **Fix:** make component base the default wherever G10/G11 is claimed (pay
the 2.05×), or restate the goal as semantic-only for union mode and gate it by
comparing `cargo metadata` unit graphs offline; label Mode B explicitly
monorepo-keyed.

### P1-2. The planner re-implements Cargo and already overshoots its own complexity stop

§16 sums ≈790 new lines
(`component 200–280 + manifest 60 + definition 80 + source 50 +
composer 200 + mirror 120 + pkg-helper 80`)
against its own rule "if the planner exceeds ~400 lines, stop and degrade".
Constructs with no worked handling/test: `[workspace.dependencies]` entries that
are themselves `path=` deps (not an edge in the member scan);
`[patch]`/`[replace]` targets outside `C(m)`; renamed/`package=` deps;
per-target path deps; duplicate version families (`Cargo.lock` has 3× `rand`,
`rand_core`, `getrandom`, `windows-sys`); member `[features]` activation. Today
the repo only exercises the manager→agent edge, so most generality is
unvalidated. **Fix:** scope the planner to present constructs (path deps, used
workspace-dep subset, resolver, resolver-3 lock, `.cargo`), degrade otherwise,
and promote E0 into a gate that asserts the planner reproduces the 5 hand
declarations exactly.

### P1-3. Mode C ("declaration adoption") cannot replace a package

§6.2 Mode C imports only `${external}/definition.nix` and composes it with the
monorepo's planner/source. The external flake's own source tree and version are
never built, so it changes at most build configuration — it is not "consume a
mirrored package's flake in place of the in-repo package and merge seamlessly".
Modes A/B do that; Mode C is semantically incoherent. **Fix:** delete Mode C, or
make it carry a full external source root and re-run the planner against that
tree (Mode B + planner delegation).

### P1-4. 24-member CI/scaling is asserted, not bounded

Measured 5-member numbers are union 367 vs component 753 (~2.05×, research
§4.5). `facet-mirror-drv-eq` instantiates component mode for every package and
`facet-component-base-identity` forces every component base; at 24 members with
many disjoint components CI builds union + all component bases + standalone
mirrors. §8 calls this "CI-only" but never bounds it. **Fix:** key gates on
changed components, cache bases, sample mirrors, or build component bases only
for touched components.

---

## P2

### P2-1. Whole-lock churn across every mirror

Any dependency bump rewrites the single `Cargo.lock` copied into all
`mirrors/<name>/`; `mirror-fresh` fails repo-wide and 24 mirror
PRs/regenerations follow (§17.2 admits). **Fix:** component-filtered lock
(design defers) or per-mirror generated lock.

### P2-2. `lib/flake` extraction prerequisites are understated

The 4 escapes are confirmed exactly (`pkg-helper.nix:11,474,1529,2116`). But all
existing per-package flakes import `lib/flake/stack/package.nix`, which imports
`service-module.nix` (1215 lines) at module scope (research §2.2); a mirror
template that drops it loses `nixosModules` and `srv.mkModule` passthru used by
several Rust packages. No `libflake` ABI/version is defined, so "helper skew" is
unpinned. **Fix:** define a minimal versioned `libflake` interface and an
explicit `srv` stub contract for mirrors; keep vendoring as the default (as
planned); make S8's isolation spike use
`--option allow-import-from-derivation false` with the stub, not just a build.

### P2-3. Author API is simpler but the migration is real churn

Removing `projectDir/deps/internalDeps` is a genuine simplification, and E1/E2
are non-breaking because `mkRustDerivation` is retained. But E5 rewrites 13
in-tree `flake.nix` files to the generated template, and every mirror must
export `packages.default`, `definition`, optional `declarationPath`,
`lib.mkPackage`, plus standard apps/checks/devShells (§6.2). That is a breaking
change for anyone consuming the current child-flake shapes.

### P2-4. `componentSource` filter environment can still diverge

Experiment `/tmp/facet-id`: two roots with differing sibling contents **and
differing `.gitignore` contents** produced the same `...-facet-members` store
path when the selected subtree matched, so the mechanism is real. But the filter
additionally reads `sourceRoot + "/.gitignore"` via
`nix-gitignore.gitignoreFilterPure` and keeps `.cargo` unconditionally;
`mkMirrorFiles` calls `.cargo/config.toml` "optional". A mirror with a different
ignore file or a `.cargo` present on only one side selects a different set.
Today there is no root `.cargo`, so latent. **Fix:** pin the ignore-file bytes
(or filter on a closed selected-dir set) and require `.cargo` to be copied
byte-identically or excluded.

### P2-5. Native-input / platform keying is admitted but unaddressed

`componentBase` keys on `definition.component.nativeProfile`; a member needing a
unique native input mis-keys the shared base (§17.6). Platform-gated member
exclusion from a component is "may" with no implementation (§12), so a Darwin
base can include Linux-only members and diverge per host. **Fix:** per-member
profile key or a per-package base override; implement the platform filter or
drop the claim.

---

## NOTE

- **No-IFD holds.** The planner uses
  `readFile`/`fromTOML`/`readDir`/`builtins.path` on evaluator-visible paths
  only; `componentSource` is a derivation wrapper; the legacy `mkRustDerivation`
  dummy fallback is pre-existing. No IFD introduced.
- **Mode B equality is conditional.** "drv identical to the in-repo package"
  holds only if B1 is resolved (byte-identical component source/key) and the
  exact same base derivation is injected; combined with P1-1 it does not hold
  for the default build.
- **`--locked` nuance:** `cargo metadata --locked` passes on a pruned member
  list; only `check`/`build` fail. Worth encoding in the gate rather than
  trusting S2.

## What FACET gets right

- Keeps `-p m` component-local resolution and treats the union base strictly as
  memoization; matches research §3.1/3.2 and avoids REWEAVE's peer-dependent
  manifest rewrite. The cargo-fingerprint argument for binary safety is
  essentially correct.
- Canonical generated root manifest + verbatim used `[workspace.dependencies]`
  subset + copied lock, with member manifests copied rather than rewritten,
  preserves `default-features = false` and member features — the right lever.
- `builtins.path` content-hash identity is real and verified; the
  `name = "cargo-workspace-source"` crane invariant is respected.
- Three executable gates (`mirror-fresh`, `mirror-drv-eq`, `adoption-eq`),
  `basePolicy="legacy"` rollback, and warn-don't-throw degradation are the right
  shape.
- Honest-limits section; explicit component-vs-union trade-off; no IFD
  regression.
