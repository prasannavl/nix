# Rust build graph — final design (dual-mode mirroring + member-local closure bases)

Status: final. Consolidates Design L (landed), the dual-mode design (Design M /
MIRROR-L), and the member-locality design (Design G4 / CLOSURE-BASES). Merges
the adjudications of three design councils. Supersedes the intermediate designs
(`design-f-build-graph`, `dual-mode-rust-build-graph`, `g4-base-locality`) as a
standalone statement.

Audience: a maintainer or reviewer who needs the whole design without the
council artifacts. Terms are defined inline.

---

## 1. Summary

The Rust packages live in a Cargo workspace inside a Nix monorepo. The build
must:

- compile each external crate as few times as possible;
- keep `.rs` edits local;
- keep a **member's** `Cargo.toml` edits local (a member manifest edit must not
  rebuild unrelated members);
- run with **no IFD** (evaluator never reads a build product);
- let each `pkgs/...` package also be **mirrored into its own repo as a
  standalone flake**, and let the monorepo **consume that mirror in place of the
  in-repo package** and merge seamlessly;
- keep a simple, intuitive consumption API and a maintenance-light codebase;
- scale to a 24-member workspace.

The design has two axes:

1. **Dependency base granularity = per member** (`base(m)` built from the
   member's own source closure), one shared full-lock vendor, `cargoArtifacts`
   inheritance only along real closure-subset (in-repo path-dependency) edges.
2. **Dual mode**: layout-preserving generated mirrors plus one `base` injection
   seam, so a mirror is byte-identical to the in-repo package and can be adopted
   in place of it.

Mode switch: `baseMode ∈ {member, union, legacy}`.

- `union` — landed Design L's single shared `--workspace` base (zero-regression
  landing; global invalidation).
- `member` — per-member closure bases (member-local invalidation; G4/G10/G11
  target).
- `legacy` — bit-for-bit Design L rollback.

---

## 2. Goals and non-goals

### 2.1 Goals

| id  | goal                                                                                                                                                                                     |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| G1  | No IFD.                                                                                                                                                                                  |
| G2  | Each external crate compiled as few times as possible.                                                                                                                                   |
| G3  | `.rs` **content** edits stay local to the edited member and its dependents.                                                                                                              |
| G4  | A **member's** `Cargo.toml` semantic edit invalidates only that member's own external closure and its dependents. Root `[workspace.dependencies]` / shared-lock edits **may** be global. |
| G5  | Simple, intuitive consumption API (repo structure may change if the API stays clean).                                                                                                    |
| G6  | Maximal cache reuse; no redundant compiles.                                                                                                                                              |
| G7  | Clean, elegant, scalable, maintenance-light, composable.                                                                                                                                 |
| G8  | Correctness first; no silent wrong builds; honest claims.                                                                                                                                |
| G9  | Pvl ↔ Abird two-repo parity.                                                                                                                                                             |
| G10 | Each `pkgs/...` package is mirrorable into its own repo as a standalone-buildable flake; `lib/flake` optionally extractable as an isolated library.                                      |
| G11 | The monorepo can consume a mirrored package's flake in place of the in-repo package and merge seamlessly (same semantics; ideally same cache).                                           |

### 2.2 Non-guarantees (explicit)

- Not bit-identical binaries across **different** bases. Semantics are equal
  (the member still resolves its own closure); artifacts differ.
- No standalone cache identity in `union` mode (a mirror is semantically equal
  but not a cache peer) — only `member` mode gives cache identity.
- Feature unions are additive; a transitive feature can still cause a bounded
  recompile in a dependent's layer.
- Manifest/lock/toolchain/profile changes are global in `union` and for
  root/lock rows in `member`; this is accepted (G4 tolerance).

---

## 3. Problem statement

### 3.1 Landed baseline (Design L)

- One shared dependency base:
  `buildDepsOnly { dummySrc = mkDummySrc (laundered
  workspace source); cargoExtraArgs = "--offline --workspace"; cargoLockContents;
  cargoVendorDir; }`.
  Its derivation inputs are the cleaned `Cargo.toml`s of **all** members, the
  single `Cargo.lock`, `.cargo/**`, and the whole-lock vendor dir. It is
  `.rs`-independent (crane's `mkDummySrc` launders manifests and stubs `.rs`).
- Member layers: `cargo build --offline -p <member>` with
  `cargoArtifacts = <base>` (or a dependency's layer), artifacts-only
  (`doInstallCargoArtifacts = true`); deployed packages and checks inherit the
  layer so artifacts never enter runtime closures.

### 3.2 Two defects

1. **Residual recompiles.** The base builds `--workspace` (the union over all
   members); a member layer resolves its own subset, so cargo recompiles the
   differing externals (e.g. `syn`, `clap`, `sha2`).
2. **Global manifest invalidation.** Because the base's inputs are all member
   manifests and the shared lock, any member `Cargo.toml` semantic change
   changes the base drv. `buildDepsOnly` hard-codes `cargoArtifacts = null`, so
   a changed base is rebuilt **from scratch**: every external recompiles, and
   every member layer (whose `cargoArtifacts` input is that base) re-runs.

### 3.3 Why simpler fixes are rejected

- **Union forcing** (rewrite member manifests to the workspace/shard union, or a
  synthetic aggregate crate) fixes the residual but makes a member's features
  depend on its monorepo peers — peer-dependent semantics — which breaks G10/G11
  (a standalone mirror has no peers). Rejected.
- **Per-signature bases with pruned locks/vendors** reduce duplication but cargo
  fingerprints the **vendor root**, so per-node pruned vendors break artifact
  reuse and chaining. Rejected in favor of one shared vendor.
- **Peer-derived cores/meets** (a node built from the intersection of members'
  declarations) can move when one member edits, invalidating unrelated members —
  a G4 violation. Rejected.
- **Component granularity** dummies all manifests of the component, so editing
  one member invalidates its siblings. Rejected for G4; retained only as the
  mirror unit.

---

## 4. Architecture and module boundaries

```text
pure eval (no IFD)                                 build time
  root Cargo.toml + member Cargo.toml + Cargo.lock    ┌─────────────────────┐
        │                                             │  baseNode(m)        │
        ▼                                             │  mkClosureBase      │
  lib/flake/rust-components.nix  ──▶ Plan ──▶         │  (deps, artifacts)  │
  (closure + declaration maps)                        └──────────┬──────────┘
                                                                 │ cargoArtifacts
                                                      ┌──────────▼──────────┐
                                                      │  memberLayer(m)     │
                                                      │  cargo build -p m   │
                                                      └──────────┬──────────┘
                                                                 │
                                              ┌──────────────────┼──────────────┐
                                              ▼                  ▼              ▼
                                         package(m)         checks(m)      devShell(m)
```

Modules:

- `lib/flake/rust-components.nix` — **pure planner**. Inputs: parsed root
  `Cargo.toml`, member `Cargo.toml`s, `Cargo.lock`, host label. Outputs the
  closure/dependency plan as plain data. No `pkgs`, no crane, no derivations.
  Uses `builtins.readDir` only on evaluator-visible path sources (glob members).
- `lib/flake/pkg-helper.nix` — **emitter**. Consumes the plan; owns all
  `craneLib` calls; unchanged public surface apart from the `base` argument.
- `lib/flake/component-bases.nix` (or a slice of the composition layer) — builds
  the per-member base nodes and threads them down.

The monorepo composition
(`flake.nix → lib/flake/root.nix →
lib/flake/default.nix → lib/flake/packages.nix`)
selects `baseMode` and injects bases.

---

## 5. Package model and consumption API

### 5.1 Author API (unchanged shape)

A package's `default.nix` still calls:

```nix
pkgHelper.mkRustDerivation {
  pkgs;
  pname = "abird-host-manager";
  version = "0.1.0";
  projectDir = "pkgs/tools/abird-host-manager";
  deps = [ "pkgs/tools/abird-host-agent" ];
  internalDeps = [ abirdHostAgent ];
  nativeCheckInputs = [ pkgs.bash pkgs.coreutils pkgs.gitMinimal pkgs.jq pkgs.util-linux ];
  buildAttrs = { nativeBuildInputs = [ pkgs.makeWrapper ]; postInstall = "..."; };
  meta = { mainProgram = "abird-host-manager"; platforms = pkgs.lib.platforms.linux; };
}
```

One new optional argument:

```nix
base ? null,   # an injected dependency base (a crane cargoArtifacts drv)
```

When `base != null`, the package inherits it instead of computing a base.
`mkRustDerivation` never computes a per-member base itself; the composition
layer does, so a package built standalone (mirror) or composed (monorepo)
differs only by what base is injected.

### 5.2 Result shape (`passthru`)

- `projectDir`, `sourcePath` (existing).
- `closureDirs` — the member's source closure `{m} ∪ transitive path deps`.
- `baseKey` — the hash-keyed identity of the member's declaration map.
- `depsBase` — the injected or computed base drv (or `null`).
- `baseMode` — `member` / `union` / `legacy`.
- `memberLayer`, `sharedDepsBase` (`null` when a base is injected), `checks`
  `{build,fmt,lint,test}`, `fmt`, `lint-fix`, `pkgOps`, optional `devShell`.

### 5.3 Consumption API (what a consumer learns once)

- Monorepo: `packages.<name>` (unchanged); a host overlay maps
  `pkgs.<name> = value.build or value`.
- Mirror/standalone: `packages.default`, `checks`, and
  `lib.<system>.mkPackage { pkgs, pkgHelper, base ? null }`.
- A package flake also exposes `passthru.definition` / `passthru.build` /
  `passthru.component` / `passthru.base` for adoption.
- The only repo-level knob is `baseMode ∈ {member, union, legacy}`; there are no
  per-package modes.

---

## 6. Dependency base model (closure bases)

### 6.1 Closure

```text
closure(m) = { m } ∪ transitiveInRepoPathDeps(m)
```

For this repo, `closure(manager) = {manager, agent}`; the other members are
singletons. A base node exists per member; `closure` is the unit of both the
base's member set and the member layer's source set, so they match exactly.

### 6.2 Base construction

`baseNode(m)` (new helper, e.g. `mkClosureBase`):

- **Source**: a real filtered source over `closure(m)`:
  - root `Cargo.toml` (with `[workspace] members` rewritten to `closureDirs(m)`)
    and root `Cargo.lock`, `.cargo/**`;
  - each `d ∈ closureDirs(m)`: its directory filtered by `mkWorkspaceSourcePath`
    (`Cargo.toml`, `Cargo.lock`, `.cargo`, sources);
  - `name = "cargo-workspace-source"` (load-bearing: crane's `sourceName`
    relocation must put every source at `/build/cargo-workspace-source`).
- **Dummy**: `dummySrc = mkDummySrc { src = closureSource; }` so the base is
  `.rs`-independent.
- **Phases**: built with `mkCargoDerivation` (not `buildDepsOnly`, which
  hard-codes `cargoArtifacts = null`), running `cargo check --all-targets`,
  `cargo build`, `cargo test --no-run` with `--offline` and the closure member
  set; `doInstallCargoArtifacts = true`.
- **Lock**: the **real full** root `Cargo.lock` (passed via
  `cargoLockContents`).
- **Vendor**: the **one shared full-lock** vendor dir, computed once from the
  real lock (`craneLib.vendorCargoDeps`). Every base and every member layer uses
  the identical vendor drv.

### 6.3 Why one shared vendor

Cargo fingerprints the **absolute vendor root**, so a byte-identical vendor at a
different path forces a recompile, and per-crate symlink farms do not help.
Therefore per-node pruned vendors (and per-node pruned locks) are rejected: they
would silently disable artifact reuse and chaining. Lock/vendor churn is global,
which G4 explicitly tolerates.

### 6.4 Chaining rule

A base node may inherit another node's artifacts only when

```text
closure(P) ⊆ closure(C)   (a real in-repo path-dependency edge)
```

Then `baseNode(C).cargoArtifacts = baseNode(P)` and crane's `.prev` delta chain
installs only the delta (`doInstallCargoArtifacts = true`). For this repo:
`closure(agent) ⊆ closure(manager)`, so `baseNode(manager)` may chain on
`baseNode(agent)`, saving the agent subtree (~65 crates).

Peer-derived cores/meets/fused sets are **not** allowed: they can move when one
member edits and would invalidate unrelated members.

### 6.5 No-widening exactness

For every member `m`, the base's `--workspace` member set is exactly
`closureDirs(m)`, which is exactly the set of directories in `memberLayer(m)`'s
source. Both builds see the same root requirement table, the same manifests,
lock, vendor, toolchain, and target, so the base compiles a subset of `m`'s
resolved units with cargo-identical fingerprints, and `memberLayer(m)`
recompiles only units whose fingerprints differ. No sibling is ever added, so no
feature can be enabled by a non-dependent peer. This is the composition-
independence property that the rejected union-forcing designs violated.

---

## 7. Member layers, packages, checks

- `memberLayer(m)` = `cargo build --offline -p <m>` with
  `cargoArtifacts = baseNode(m)` (or the injected `base`), artifacts-only,
  filtered compile inputs (no `postInstall`, no `nativeCheckInputs`, no
  `checkEnv`).
- `package(m)` = `buildPackage` with the same `cargoArtifacts`; artifacts are
  not published (crane sets `doInstallCargoArtifacts = false`).
- `checks.lint` = `cargoClippy` with `cargoArtifacts = memberLayer(m)`.
- `checks.test` = `cargoTest` with the same artifacts and its check inputs; the
  base's `cargo test --no-run` primes test targets so `checks.test` reuses them.
- `checks.fmt` needs no artifacts.
- Internal dependencies: `internalDeps` carries the dependency package; the
  member's source includes the dependency's `projectDir`; artifacts come from
  the dependency's `memberLayer` (or the closure base when the dependency is in
  the same closure). Fan-in (≥2 internal deps) uses the existing full-archive
  join, unexercised today.

---

## 8. Invalidation matrix

`Dep(m)` = transitive in-repo dependents. "unrelated" = no path edge either way.

| edit                                   | `base(m)`   | unrelated bases | `layer(m)` | dependent layers | unrelated layers |
| -------------------------------------- | ----------- | --------------- | ---------- | ---------------- | ---------------- |
| `m` `.rs` content                      | no          | no              | yes        | yes              | no               |
| `m` `.rs` add/remove under `src/`      | yes (local) | no              | yes        | yes              | no               |
| `m` `Cargo.toml` dep-relevant semantic | **yes**     | **no**          | **yes**    | **yes**          | **no**           |
| `m` `Cargo.toml` metadata only         | no          | no              | no         | no               | no               |
| `m` internal path edge change          | yes (local) | no              | yes        | yes              | no               |
| root `[workspace.dependencies]`        | yes (all)   | yes             | all        | all              | all              |
| root `[workspace] members`             | global      | global          | global     | global           | global           |
| `Cargo.lock`                           | all bases   | all             | all        | all              | all              |
| `.cargo/**`                            | global      | global          | global     | global           | global           |
| toolchain / nixpkgs / crane / profile  | global      | global          | global     | global           | global           |

Locality statement for G4 (row 3):

```text
Δ(m) = { base(m) } ∪ { base(d) : m ∈ closure(d) }
     ∪ { layer(m) } ∪ { layer(d) : m ∈ closure(d) }
```

Every unrelated base and layer is byte-identical. The global rows are exactly
the tolerated ones plus unavoidable toolchain/profile changes.

Known local wart: a `.rs` **add/remove** under `src/` changes `base(m)` because
`mkDummySrc` reads `src/`, `src/lib.rs`, `src/main.rs`, `src/bin/` at eval time.
A manifest-only base would remove this; deferred.

---

## 9. Feature normalization (W10) policy

- Shared dependency features are declared once in the root
  `[workspace.dependencies]`; member manifests use bare `{ workspace = true }`
  and add member-specific features only when genuinely member-specific.
- This removes the _direct_ feature divergence that caused avoidable residual
  recompiles. The _transitive_ feature union residual remains and is accepted
  (bounded, additive); a diagnostic gate reports it
  (`cargo metadata -e
  features` diff), it is not a correctness backstop.
- The union policy widens some members' features (additive only). That is the
  landed policy; REWEAVE's peer-dependent forcing is rejected.

---

## 10. Mirroring (G10)

### 10.1 Unit and layout

- The mirror unit is the **path-connected component** (for this repo:
  `{manager, agent}`; `bridge`; `wrecking`; `hello-rust`).
- The mirror is **layout-preserving**: the component subtree is copied at the
  same monorepo-relative paths, with a byte-copied root `Cargo.toml` and
  `Cargo.lock` and `.cargo/**`. Because `builtins.path` is content-addressed and
  the relative layout is preserved, the filtered source, the base node, and the
  member layer derivations are **identical** in monorepo and mirror.

### 10.2 Generation and drift gates

- Generate mirrors from the **evaluated git revision** (`git ls-files` /
  `git archive`) — never from a mutable worktree. Every tracked byte under the
  selected dirs is copied, so no untracked file can perturb the source hash.
- Child-flake wrapper files (`flake.nix`, `flake.lock`) must not sit inside the
  copied member dirs.
- Gates: `mirror-fresh` (generated == committed mirror bytes), `mirror-parity`
  (mirror package drv == in-repo package drv), `mirror-standalone` (the mirror
  builds with no monorepo root and uses the crane overlay, not the
  `rustPlatform` fallback).

### 10.3 Package-flake contract

Per system: `packages.<p>`, `packages.default`, `checks.{build,fmt,lint,test}`,
`lib.<system>.mkPackage { pkgs, pkgHelper, base ? null }`, and
`passthru.definition` / `passthru.build` / `passthru.component` /
`passthru.base`. Standalone builds use the mirror's own `baseNode(m)`
(`baseMode = member`).

### 10.4 `lib/flake` extraction tiers

- **Tier 1 (default): vendored library.** The mirror vendors the computed import
  closure of `lib/flake` (pkg-helper plus the `service-module` slice its
  passthru needs). No version skew because it is generated.
- **Tier 2 (later): isolated library flake.** Requires parameterizing the
  relative-path escapes in `pkg-helper.nix` and the ~26 `../..` sites across
  `lib/flake`, and splitting `service-module.nix`; consumers pin one lib rev via
  `follows`.

---

## 11. Adoption and seamless replacement (G11)

### 11.1 Seam

- Composition threads a defaulted `externalPackagesFor` through
  `flake.nix → root.nix → default.nix →
  packages.nix`. By default it is empty
  (in-repo packages); setting it swaps a package for the mirror by manifest
  name.
- The mirror exposes `lib.<system>.mkPackage { pkgs, pkgHelper, base ? null }`.
  The monorepo injects its own `baseNode(m)` (or any base) so the adopted
  package is identical to the in-repo one.

### 11.2 Equality matrix

| mode     | standalone base           | composed == in-repo    | standalone == in-repo                | use                    |
| -------- | ------------------------- | ---------------------- | ------------------------------------ | ---------------------- |
| `member` | mirror's own closure base | yes (`drvPath`)        | **yes** (`drvPath`)                  | G4/G10/G11 target      |
| `union`  | mirror's closure base     | yes with injected base | semantically equal, not a cache peer | landing/rollout        |
| `legacy` | L per-package             | yes                    | yes                                  | bit-for-bit L rollback |

In `member` mode, `base(m)` is a pure function of the member's closure, so
standalone, composed, and in-repo all produce the same derivation. In `union`
mode, semantic equality is checked with `cargo metadata -e features` (not
`drvPath`).

### 11.3 Gates

`adoption-eq` (adopted drv == in-repo drv), `mirror-parity`, `resolution-fresh`
(feature diff), and the no-IFD eval of every mirror.

---

## 12. Dev-deps, tests, native inputs, platform gating

- Dev-dependencies are part of the member's closure; the base's
  `cargo test
  --no-run` primes them; `checks.test` reuses them.
  Build/dev/target domains are separate in cargo's resolver, so dev-deps do not
  leak into normal units.
- A base node carries the closure's **native-input profile** (canonical
  `nativeBuildInputs`/`buildInputs`); member-specific check inputs stay on the
  member layer/checks. The profile is part of the node identity so two members
  with different native inputs are not falsely shared.
- Platform gating: members are filtered by `hostPlatform` before the closure and
  base are computed, so a non-buildable member cannot break unrelated bases.
  `meta.platforms` drives the filter; the composition layer owns it.

---

## 13. Diagnostics and degradation

- `passthru.baseKey`, `closureDirs`, `depsBase`, `baseMode` on every package.
- A flake output (e.g. `rustPlan`) renders closures, base nodes, chaining edges,
  and any degradation reasons; eval-only, no build.
- `lib.warn` (never `throw`) at every degrade trigger: a glob member, a member
  with a `[features]` table that pure eval cannot model, an unparseable lock
  entry, a missing path dep.
- Fall back cleanly: `base != null` wins; else `baseMode` decides; `legacy`
  reproduces Design L bit-for-bit.

---

## 14. Cost model and the mandatory 24-member gate

Measured at 5 members (external closure sizes):
`hello 0, agent 63, manager 219,
bridge 221, wrecking 208`; union 367;
per-member sum 753 → **2.05×** the union. With the `agent ⊆ manager` chain the
sum drops to ~688 → **1.88×**.

- `member` costs ~2× cold compiles vs `union`, measured.
- 24-member projections from the council disagreed (1.4×–7.5×); they are **not**
  a default input.
- **Gate:** `member` does not become the repository default until its actual
  cost is measured on the real 24-member manifests. Until then the landing
  default is `union` (zero regression), with `member` opt-in per component.

Levers if the cost is unacceptable (all deferred, all measured first): a
generated declaration-keyed stub workspace to dedup resolution-identical
members; sharing only along provable closure-subset edges; caching the base
across commits via an explicit pinned parent input (stateful; out of scope).

---

## 15. Migration plan (staged)

1. **L2 — planner diagnostic.** Land `rust-components.nix`, `passthru.baseKey`/
   `closureDirs`, and the `rustPlan` output; no build change. Validate closures
   and base keys against the real lock.
2. **F0 — `base` seam.** Add `base ? null` and `baseMode` (default `union`,
   which computes exactly Design L's base). Zero behavior change; eval assert
   that `union` reproduces the L base drv.
3. **F1 — per-member bases, one component.** Wire `member` mode for one
   component (e.g. `nats-http-bridge`); verify invalidation and parity gates.
4. **F2 — closure chaining.** Enable
   `baseNode(manager).cargoArtifacts =
   baseNode(agent)`; verify the delta
   reuses.
5. **F3 — mirrors.** Generate layout-preserving mirrors; land `mirror-fresh` /
   `mirror-parity` / `mirror-standalone`; migrate the 13 child-flake wrappers.
6. **F4 — adoption.** Thread `externalPackagesFor`; land `adoption-eq`.
7. **F5 — `lib/flake` extraction.** Tier 1 vendoring, then Tier 2 if needed.
8. **Default flip.** Set `member` as default only after the 24-member
   measurement gate passes.

Rollback: `baseMode = legacy` (or `base = null` with `useWorkspaceDeps =
false`)
reproduces Design L bit-for-bit.

---

## 16. Validation: spikes and gates

Spikes (before the corresponding flip):

- **S1** a per-member base builds `--offline` with the shared vendor and leaves
  `Cargo.lock` unchanged.
- **S2** a member manifest edit leaves unrelated base drvs byte-identical and
  changes only `base(m)` + dependents (the G4 claim).
- **S3** `baseNode(manager)` chaining on `baseNode(agent)` reuses (only the
  delta compiles) with the shared vendor.
- **S4** `.rs` content edits leave every base byte-identical; `.rs` add/remove
  affects only `base(m)`.
- **S5** a layout-preserving mirror yields identical source/base/member drv
  paths.
- **S6** adoption (`mkPackage { base }`) yields the in-repo drv path.
- **S7** an injected base vs a computed base produce the same deployed package
  semantics (`cargo metadata -e features`).
- **S8** the fan-in join evaluates for a synthetic two-internal-dep member.
- **S9** the 24-member cost measurement.

Standard gates:

- V1 no IFD (every package and mirror evaluates with
  `--option allow-import-from-derivation false`).
- V2 G4 invalidation (S2) and G3 `.rs` locality (S4) in CI for a canary member.
- V3 G10/G11 equality (`mirror-parity`, `adoption-eq`) in `member` mode.
- V4 lock fidelity (`cargo metadata --offline` shows no version drift).
- V5 closure isolation (`nix path-info -r` shows no artifact archive in deployed
  packages).
- V6 eval tests: closures deterministic; every member in exactly one base; no
  chain without a closure-subset edge; degrade-without-throw.
- V7 `nix flake check` and the isolated child flake builds.

---

## 17. Risks

1. **Pure-eval fidelity.** The planner reads manifests + lock; it cannot see
   cargo's feature activation. Mitigation: conservative (separate bases), the
   `cargo metadata -e features` diagnostic, and `lib.warn` degrade.
2. **Cost.** `member` is ~2× cold compiles at 5 members; 24-member cost is
   unmeasured. Mitigation: `union` default, opt-in `member`, the mandatory gate,
   deferred stub dedup.
3. **`.rs` add/remove** invalidates `base(m)`. Mitigation: local only; a
   manifest-only base is a deferred lever.
4. **Vendor coupling.** One shared vendor means lock/vendor churn is global
   (accepted). Per-node vendors are rejected because they break reuse.
5. **Mirror layout constraints.** Non-Nix `cargo` in a mirror needs the devShell
   to rewrite the member list, or a generated filtered root.
6. **Complexity.** The system is larger than L; the maintenance budget is
   bounded (planner ~120–200 lines, emitter delta ~150, generator ~220, tests
   ~100) and every addition must fit the budget or degrade.

---

## 18. Decision log (adjudications)

Accepted:

- Per-member closure bases (`member`) as the G4/G10/G11 target; `union` as the
  zero-regression landing; `legacy` as the bit-for-bit rollback.
- One shared full-lock vendor; no pruned locks or vendors (vendor-root
  fingerprinting).
- Chaining only along real closure-subset edges; no peer-derived core/meet.
- Real filtered source for base nodes (highest fidelity); generated stub
  workspace deferred as a measured dedup lever.
- Generated layout-preserving mirrors from the evaluated git revision; `base`
  injection; `externalPackagesFor` adoption.
- Minimal API: `base ? null` + `baseMode ∈ {member, union, legacy}`.

Rejected:

- REWEAVE / union manifest rewrite (peer-dependent semantics; breaks G10/G11).
- F-union synthetic aggregate crate (one aggregate cannot represent
  `default-features` polarity; global base churn; lock/`cargo metadata`
  friction).
- F-cluster / per-signature bases with pruned locks/vendors (vendor-root
  fingerprinting; unmeasured cost).
- FACET package-definition rewrite (re-implements cargo for a benefit
  layout-preserving mirrors make unnecessary).
- ECHO "mirror-first is the unit of truth" as an architecture (it converged on
  the same mechanism; the monorepo direct-imports in-repo files).
- Component granularity as a base mode (editing one member invalidates its
  siblings); retained only as the mirror unit.
- Peer-derived cores/meets/fused sets (G4 violation).

---

## 19. References

- Landed Design L: `.agents/docs/plans/design-l-implementation-2026-09.md`,
  `lib/flake/pkg-helper.nix`.
- Prior designs (retained as adjudication record):
  `.agents/docs/plans/rust-workspace-build-graph-2026-09.md`,
  `.agents/docs/plans/design-f-build-graph-2026-09.md` (REWEAVE, rejected).
- Review and goal notes:
  `.agents/docs/notes/tooling/rust-build-graph-review-2026-09.md`,
  `.agents/docs/notes/tooling/rust-build-graph-decision-2026-09.md`,
  `.agents/docs/notes/tooling/rust-build-graph-dual-mode-goals-2026-09.md`,
  `.agents/docs/notes/tooling/rust-build-graph-g4-locality-2026-09.md`.
- Crane rev used in the design: `7rradzysxg41b2yx7qnh2f2bw73py192`
  (`lib/mkDummySrc.nix`, `lib/buildDepsOnly.nix`, `lib/mkCargoDerivation.nix`,
  `lib/setupHooks/installCargoArtifactsHook.sh`,
  `lib/setupHooks/inheritCargoArtifactsHook.sh`, `lib/vendorCargoDeps.nix`).
