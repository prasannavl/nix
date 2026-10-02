# Rust build-graph work — handoff (READ THIS FIRST)

Repo: `/home/pvl/src/nix` (the Pvl `nix` monorepo). Sister repo:
`/home/pvl/spaces/abird/src/z` (Abird; the `abird` git remote).

This document is the entry point for an agent picking up the Rust build-graph
work. It records the original problem, every design and council, all decisions,
the verified facts, the current repository state, the pending items, and a
ready-to-paste starting prompt. Everything durable lives under
`.agents/docs/**`; the raw council candidates/critiques are preserved under
`.agents/docs/notes/tooling/rust-build-graph-councils/`.

---

## 0. Starting prompt (paste this to the next agent)

```text
You are picking up an in-progress design effort on the repo-wide Rust (and
multi-ecosystem) build & cache architecture in /home/pvl/src/nix.

FIRST, read this handoff in full, then follow its reading order:
  .agents/docs/notes/tooling/rust-build-graph-handoff-2026-09.md

Do not re-derive or re-litigate anything the handoff marks as "verified fact" or
"decided". Do not change code in this session unless explicitly asked; this is a
design/decision phase.

Then confirm back to me: (1) a short summary of the current state, (2) the open
decisions, and (3) your recommended next step. The immediate open question is the
go/no-go spike on the unit-DAG/Capsule-Ledger design (producer fidelity), versus
staying with the Design G4 closure-bases + Design M mirroring path. Ask me before
starting anything expensive.
```

---

## 1. One-paragraph state

Design **L** is landed (Rust members share one `.rs`-independent dependency base
and add per-member artifact layers). A four-lane fresh review found no blockers
but produced P1/P2 items. Three design councils followed: (1) a "Design F"
council that produced **REWEAVE** (later rejected); (2) a dual-mode council that
produced **Design M / MIRROR-L** (mirrorable standalone packages + `base`
injection); (3) a locality council that produced **Design G4 / CLOSURE-BASES**
(per-member closure bases, one shared full-lock vendor, closure-subset chaining,
`baseMode ∈ {member, union, legacy}`), which supersedes Design M's `component`
base mode. A consolidated Rust design and a **multi-ecosystem build fabric**
(Rust · Go · Node · Deno · Python · C++) were then written. A newer, more
ambitious **unit-DAG "Capsule · Ledger · Modes"** design (provided from outside)
resolves the sharing-vs-locality tension but is **not yet validated**; its
adoption hinges on a producer-fidelity spike. Several design docs are still
untracked; nothing from the design phase is committed.

---

## 2. The original problem and its root cause

Symptom: the `abird-host-manager-deps` derivation rebuilt on ordinary source
(`.rs`) edits.

Root cause (pre-fix revision `391df360`): `lib/flake/pkg-helper.nix`
`mkRustDerivation` set `dummySrc = buildSrc` — the **real filtered source** — so
crane used it verbatim as `src`; the dependency derivation therefore depended on
`.rs` content. The same defect existed in `mkTrunkProject` and
`mkCraneRustPackage`.

Facts established during diagnosis (do not relitigate):

- `builtins.readDir <derivation>` is IFD.
- crane's `buildDepsOnly` honors an explicit `dummySrc` (and warns that `src` is
  ignored).
- `mkDummySrc` keeps `Cargo.toml`/`Cargo.lock`/`.cargo` and stubs `.rs`; its
  output is independent of `.rs` **content**.
- `sourceName` must match (`cargo-workspace-source`) so sources unpack to
  `/build/cargo-workspace-source`.
- `inheritCargoArtifacts` recurses a single `.prev` parent; `cargoArtifacts` is
  a single path, not a list.
- `buildPackage` sets `doInstallCargoArtifacts = false` by default.

Additional verified current-state facts (Abird-scale, from the fabric work):

- compile-time hidden inputs exist and matter: `option_env!` (`abird-protocol`),
  `include_str!("../Cargo.toml")` / `tauri.conf.json` / `main.rs` (`abird-app`),
  `include_str!("memory-schema.sql")` (`abird-agent`). The real manifest is a
  compile input.

### 2.1 Repository shapes

- **Pvl `nix`**: 5 root members (`hello-rust`, `nats-http-bridge`,
  `abird-host-agent`, `abird-host-manager`, `nats-wrecking-ball`); `Cargo.lock`
  v4, **372** packages; `resolver = "3"`; only internal edge
  `abird-host-manager → abird-host-agent`; `hello-rust-isolated` has its own
  `[workspace]` and is not a root member. Currently also example Node/Python/Go
  packages and one Python test requirements file; no Deno or C++.
- **Abird** (via the `abird` remote): **24** root members, `Cargo.lock` =
  **804** packages (24 local, 780 registry), **44** `[workspace.dependencies]`
  entries, **192** `workspace = true` declarations in root members, **7** path
  edges (`abird-app→abird-protocol`, `abird-web→abird-protocol`,
  `abird-agent→abird-protocol`, `abird-host-manager→abird-host-agent`,
  `tg-parrot→parrot-core`, `zulip-parrot→parrot-core`,
  `zulip-robin→robin-core`). Toolchain: nixpkgs `6d663c05…` (nixos-26.05), crane
  `73b9805…`, rustc/cargo `1.95.0`.

---

## 3. Constraints and goals

Hard constraints:

- **No IFD** (the evaluator must never read a derivation result). Enforced by
  the repo's lint and tests; verified with
  `--option allow-import-from-derivation false`.
- Correctness first.

Goals (used throughout; G10/G11 were added later, G5 was relaxed):

| id  | goal                                                                                                                                                                             |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| G1  | No IFD.                                                                                                                                                                          |
| G2  | Each external crate compiled as few times as possible.                                                                                                                           |
| G3  | `.rs` **content** edits stay local to the edited member and its dependents.                                                                                                      |
| G4  | A **member's** `Cargo.toml` semantic edit invalidates only that member's own external closure + dependents. Root `[workspace.dependencies]`/shared-lock edits **may** be global. |
| G5  | Simple, intuitive consumption API (repo structure may change if the API stays clean).                                                                                            |
| G6  | Maximal cache reuse.                                                                                                                                                             |
| G7  | Clean, elegant, scalable, maintenance-light, composable.                                                                                                                         |
| G8  | No silent wrong builds; honest claims.                                                                                                                                           |
| G9  | Pvl ↔ Abird two-repo parity.                                                                                                                                                     |
| G10 | Each `pkgs/...` package also mirrorable into its own repo as a standalone-buildable flake; `lib/flake` optionally extractable as an isolated library.                            |
| G11 | The monorepo can consume a mirrored package's flake in place of the in-repo package and merge seamlessly (same semantics; ideally same cache).                                   |

G4's requirement note and option space:
`.agents/docs/notes/tooling/rust-build-graph-g4-locality-2026-09.md`. G10/G11's
requirement note:
`.agents/docs/notes/tooling/rust-build-graph-dual-mode-goals-2026-09.md`.

---

## 4. Chronological work log

### Phase 0 — Diagnosis

Root cause found (above). Empirical drv-path probes confirmed the base was
source-dependent.

### Phase 1 — Design L (landed)

Implemented in `lib/flake/pkg-helper.nix`, wired in `pkgs/manifest.nix`,
`pkgs/tools/abird-host-manager/default.nix`,
`pkgs/tools/abird-host-agent/default.nix`.

Mechanics (symbols in `lib/flake/pkg-helper.nix`): `mkWorkspaceSourcePath`,
`mkCargoWorkspaceSource`, `rustWorkspaceMembers`, `isWorkspaceMember`,
`mkRustWorkspaceSource`, `mkSharedRustDepsBase`, `mkCargoArtifactsJoin`;
`mkRustDerivation` gained `useWorkspaceDeps` / `internalDeps`, `workspaceMode`,
`resolvedDeps`, `prefixNode`, `dependencyArtifacts`, `memberLayerOf`,
`memberLayer` (artifacts-only `cargoBuild`), `cargoArtifacts`,
`internalDepsGuard`, `perProjectSourcePath`; `passthru` exposes
`memberLayer`/`sharedDepsBase`/`projectDir`. `exportCargoArtifacts` was removed.

Also landed: **feature normalization (W10)** — shared dependency features moved
to root `[workspace.dependencies]`; members use bare `{ workspace = true }`;
`Cargo.lock` unchanged; the union exactly equals the union of the removed
per-member lists (one additive widening: `nats-wrecking-ball` gains tokio
`io-util`/`net`/`process`). `abird-host-agent` checks got `rsync`.

The original 9-commit series (pre-rebase hashes): `0a75ea13`, `2e56abaa`,
`1e462db6`, `99c3ff55`, `dc3835eb`, `d19d9826`, `6461e398`, `acded422`,
`a43b811d`.

Work items/spec: `.agents/docs/plans/design-l-implementation-2026-09.md`.
Original handoff/design:
`.agents/docs/plans/rust-workspace-build-graph-2026-09.md`.

**Post-resync state (important):** an external resync rebased/squashed the
series into **`30a15c0a feat(flake): share rust workspace deps per member`**
(plus `a0cd56c9 docs(agentic): plan the repo-wide rust build graph` and
`8d5ea4a1 docs(agentic): record rust build-graph fresh review`), which are now
in `origin/master`. The old branch tips remain but are superseded:
`agent/rust-build-graph-20260929` (`1e462db6`),
`agent/rust-feature-norm-20260929` (`a43b811d`).

### Phase 2 — Fresh review of the DAG series

Four lanes (correctness; design; adversarial/boundary; empirical with shell).
Verdict: **OK with notes; no blocker, no confirmed correctness regression.**

Verified to hold: no IFD; one shared `.rs`-independent base; artifacts-only
member layer with no closure leak (agent closure ≈53.8 MB, references only
glibc/gcc-lib); locality by dry-run; `.prev` chaining; graceful degradation;
`Cargo.lock` unchanged.

Findings (recorded in
`.agents/docs/notes/tooling/rust-build-graph-review-2026-09.md`):

- **P1-A** the shared base is an unfiltered repo-wide single point of failure
  (no member list / host filter / native-input seam).
- **P1-B** mode selection is silent and unobservable (no `lib.warn`, no passthru
  mode, no `rustPlan`).
- **P1-C** docs contradict the code (feature normalization documented as
  deferred while landed; `cargo-workspace-2026-04.md` said the opposite of the
  new invariant).
- **P2-a** per-package `buildAttrs` (`postInstall`, `nativeBuildInputs`, env)
  leak into the artifacts-only `memberLayer`.
- **P2-b** `internalDeps` validated twice and independently; the guard is not
  forced in the `craneLib == null` fallback.
- **P2-c** `resolvedDeps` dedups before `normalizeMemberPath`; duplicate layers
  reach the join.
- **P2-d** workspace mode rejects a derivation/table `cargoLock`.
- **P2-e** `buildPackage` keeps `doCheck = true`, so test targets recompile at
  deploy; `checks.fmt` gets no artifacts.
- **P2-f** the normalization invariant is unguarded.
- **P2-g** no tests for the graph properties / fan-in.
- **P2-h** `mkCargoArtifactsJoin` is dead in-repo and its build is unverified.
- Notes: `.rs`-stability is narrower than stated (adding/removing a file under
  `src/lib.rs`, `src/main.rs`, `src/bin/` changes the shared base drv, because
  crane `readDir`s those at eval time); a stale `exportCargoArtifacts` mention;
  a split code span; manager's `deps`/`internalDeps` double declaration.

### Phase 3 — Council 1 → Design F (REWEAVE), later rejected

Flow: researcher ∥ explorer → staff engineer A (F-union synthetic aggregate
crate) → critic; then engineers B (F-cluster per-signature bases) and C (REWEAVE
manifest rewrite) each → critic → engineering manager.

Outcome: **REWEAVE** adopted (force the union by rewriting member manifests to
the shard's external union). Artifacts:
`.agents/docs/plans/design-f-build-graph-2026-09.md` (superseded banner added),
and council artifacts under
`.agents/docs/notes/tooling/rust-build-graph-councils/council-1-design-f/`
(`plan-b.md` = F-cluster, `plan-c.md` = REWEAVE, `critique-b.md`,
`critique-c.md`, `final-plan.md`). Candidate A's full text was inline only (its
verdicts are in the final doc).

Why REWEAVE was rejected (Phase 5): union forcing makes a member's features
depend on its monorepo peers — peer-dependent semantics — which breaks G10/G11
(a standalone mirror has no peers).

### Phase 4 — Dual-mode goals → Council 2 → Design M (MIRROR-L)

New goals G10/G11. Stage-1 finding: landed L already resolves member builds
package-locally; the only monorepo-keyed artifact is the shared base. Verifying
the escape mechanism: layout-preserving sources + `builtins.path` give identical
store paths; the **vendor root is fingerprinted** by cargo (a byte-identical
vendor at another path recompiles).

Flow: researcher ∥ explorer → engineers E1 (L-KEEP), E2 (FACET:
definition/adoption), E3 (ECHO: mirror-first) → critiques → manager.

Outcome: **Design M / MIRROR-L** — keep L semantics; add one `base` artifact
seam; build bases in the composition layer; generate layout-preserving
byte-identical mirrors from the evaluated git revision; adopt via
`externalPackagesFor`; `basePolicy ∈ {union, component, legacy}`; `lib/flake`
extraction tiers. Artifacts:
`.agents/docs/plans/dual-mode-rust-build-graph-2026-09.md`,
`.agents/docs/notes/tooling/rust-build-graph-dual-mode-goals-2026-09.md`, and
`.agents/docs/notes/tooling/rust-build-graph-councils/council-2-dual-mode/`
(`research.md`, `plan-e1..3.md`, `critique-e1..3.md`, `final-plan.md`).

### Phase 5 — G4 locality → Council 3 → Design G4 (CLOSURE-BASES)

Operator requirement G4: a member manifest edit must be member-local. Stage-1
verified: subset sources and generated stub deps-workspaces work (a stub-agent
workspace resolved the identical 65-package closure offline); **pruned locks are
`--offline`-safe** with the vendor dir as the version pin; **per-node pruned
vendors break chaining** (vendor-root fingerprinting).

Flow: researcher ∥ explorer → engineers E1 (KEYSTONE: closure-keyed subset
bases), E2 (DELTA-LATTICE: incremental base DAG), E3 (CLASSNODE:
resolution-class nodes) → 2 critics (correctness/cost;
architecture/G10-G11/scaling) → manager.

Outcome: **Design G4 / CLOSURE-BASES** — per-member closure bases from a real
filtered source; **one shared full-lock vendor** (no pruned locks/vendors);
`cargoArtifacts` inheritance only along real closure-subset edges
(`closure(P) ⊆ closure(C)`; e.g. `agent ⊆ manager`); minimal API `base ? null` +
`baseMode ∈ {member, union, legacy}`; `component` removed as a base mode (kept
only as the mirror unit). Artifacts:
`.agents/docs/plans/g4-base-locality-2026-09.md` (Design M amended with a
banner), `.agents/docs/notes/tooling/rust-build-graph-g4-locality-2026-09.md`,
and `.agents/docs/notes/tooling/rust-build-graph-councils/council-3-g4/`
(`research.md`, `explore.md`, `plan-e1..3.md`, `critique-c1.md`,
`critique-c2.md`, `final-plan.md`).

### Phase 6 — Consolidated Rust design

`.agents/docs/plans/rust-build-graph-final-2026-09.md` — one self-contained
statement merging L + M + G4 (goals, architecture, API, closure bases,
invalidation matrix, mirroring/adoption, extraction tiers, cost + 24-member
gate, migration, validation spikes, risks, decision log). This is the best
single-document Rust overview.

### Phase 7 — Multi-ecosystem build fabric

`.agents/docs/plans/multi-ecosystem-build-fabric-2026-09.md` — generalizes the
unit-DAG into one fabric for Rust · Go · Node · Deno · Python · C++: declaration
→ resolver(producer) → resolved units → committed ledger → executor → assembly;
the generic unit descriptor; the two-digest freshness model
(`resolutionDigest` + `targetShapeDigest`); the three edge kinds (resolver
edges, compile overlays, Nix package edges); **capability tiers + fail-closed
modes** (`unit` / `native` / `legacy`); per-ecosystem adapters; soundness
analysis; cross-ecosystem composition; repo integration; validation/rollout.

Notable additions during this phase (from follow-up questions):

- **Deno**: two resolution modes — `npm:` specifiers via `deno.lock`/`DENO_DIR`
  (no `node_modules`), and `nodeModulesDir` + `package.json` + `deno install`;
  the `node_modules` mode **delegates npm resolution/tree materialization to the
  Node adapter**. Native `.node` addons: the Deno runtime generally cannot load
  Node-ABI addons → recorded capability `runtimeSupportsNativeAddons = false` →
  demote to Node ecosystem / WASM alternative / fail closed.
- **Python C/C++/Cython/CFFI/PyO3 extensions**: ABI is an identity field
  (`py3-none-any`, `abi3`, versioned `cp312`/`SOABI`, PyPy, free-threaded,
  platform tag); two unit kinds (wheel install = tier A; sdist build = tier B/C)
  decomposed into codegen units (Cython/cffi/protobuf) and native units (C, C++,
  Rust/PyO3, Fortran) with declared native policy and vendored
  `[build-system]
  requires`; `auditwheel`/`delocate` are packaging.
- The fabric added a unifying note: **native extension modules (Rust `-sys`,
  Node `node-gyp`, Python C/C++/PyO3, C++ objects) are ordinary units with an
  ABI-bearing identity** — one mechanism, differing ABI fields and toolchains.

### Phase 8 — The unit-DAG "Capsule · Ledger · Modes" design (external) and the tension

A newer design was provided (Rust build + cache architecture: capsules,
content-addressed unit ledger, two-digest freshness, three edge kinds,
per-capsule modes `unit`/`cargo`/`legacy`, cross-compilation roles, native
policy, compile env, mirror/provider contract). It is the full per-unit DAG
("O7") made practical by (a) committing cargo's resolution as data (no IFD) and
(b) per-capsule fail-closed modes.

Assessment recorded here: it **dissolves the earlier "share ⇒ peer-dependent, or
exact ⇒ duplicated" dichotomy**, because it changes two assumptions — sharing
granularity becomes the individual cargo unit (content-addressed, so identical
units dedup and divergent ones split), and resolution moves out of eval into a
committed, cargo-produced artifact. It sits between the union base (fewer cold
compiles, peer-dependent) and per-member bases (more cold compiles, exact):
compile count = number of distinct resolved units. Its soundness is conditional
on **producer fidelity** (capturing cargo's resolver-v2/v3 host/target feature
split, proc-macro/build-dep edges, `[patch]`, build-script results) — the
design's own top risk.

---

## 5. Decisions log

Accepted:

- **No IFD** (hard, throughout).
- Adopt **Design L** now; move to a finer design later.
- `memberLayer` is artifacts-only; member builds use per-member sources so `.rs`
  edits stay local; the shared base uses a laundered dummy source.
- `internalDeps` takes package derivations; source dirs auto-union via
  `passthru.projectDir`; graceful degradation when a dep lacks a `memberLayer`.
- **W10 direct feature normalization landed**; the transitive union residual is
  accepted (bounded, additive).
- **Design M (MIRROR-L)**: one `base` seam; layout-preserving mirrors generated
  from the evaluated git revision; `externalPackagesFor` adoption;
  `basePolicy ∈ {union, component, legacy}`; `lib/flake` extraction tiers.
- **Design G4 (CLOSURE-BASES)**: per-member closure bases; **one shared
  full-lock vendor** (no pruned locks/vendors); chaining only along real
  closure-subset edges; minimal API `base ? null` +
  `baseMode ∈ {member, union, legacy}`; `component` removed as a base mode; a
  mandatory 24-member cost measurement before `member` becomes the default.
- **Multi-ecosystem fabric**: capability tiers + fail-closed modes; native
  extension modules modeled uniformly; Deno `node_modules` delegates to the Node
  adapter; Deno native addons are a runtime capability (fail-closed); Python
  extension modules are codegen + native units with ABI identity.
- **G4 vs sharing tension**: resolved in principle by the unit-DAG design
  (per-unit content addressing + committed resolution), **pending validation**.

Rejected (with reasons):

- **REWEAVE / union manifest rewrite**: peer-dependent semantics break G10/G11.
- **F-union synthetic aggregate**: one aggregate cannot represent
  `default-features` polarity; global base churn; lock/`cargo metadata`
  friction.
- **F-cluster / per-signature bases with pruned locks/vendors**: vendor-root
  fingerprinting; measured ~2.05×; unmeasured at scale.
- **FACET package-definition rewrite**: re-implements cargo for a benefit
  layout-preserving mirrors make unnecessary.
- **ECHO "mirror-first is the unit of truth"**: converged on the same mechanism;
  the monorepo direct-imports in-repo files.
- **Peer-derived cores/meets/fused sets**: a member edit can move them and
  invalidate unrelated members (G4 violation).
- **Component granularity as a base mode**: editing one member invalidates its
  siblings; retained only as the mirror unit.

---

## 6. Verified facts (do not relitigate)

1. **Cargo feature unification is selection-based**: one invocation unifies
   features across the dependency graphs of all `-p`-selected packages; merely
   being a workspace member (not selected) does not unify. Separate domains:
   normal, build-dep/proc-macro/host, target-gated, dev. Features are additive;
   `default-features = false` cannot subtract.
2. **Reuse needs matching `-C metadata` (features/profile) and fingerprint.**
   The physical `cargoVendorDir` path is part of the fingerprint (one shared
   vendor required). The unpack dir/basename `cargo-workspace-source` must
   match.
3. **crane defaults `cargoExtraArgs = "--locked"`** (aborts when a synthetic
   workspace adds packages); `--offline` rewrites the lock additively when pins
   match exactly, else silently downgrades. `buildDepsOnly` hard-codes
   `cargoArtifacts = null`. `buildPackage` install runs `cargo metadata` without
   `--offline`.
4. **crane artifacts** = `.prev` symlink + delta; a single parent; fan-in needs
   a full-archive join. `mkDummySrc` derives `sourceName` from the input
   basename.
5. **Residual in Design L**: a member's `-p m` build resolves a subset, so it
   recompiles externals the shared `--workspace` base built with the union.
6. **G4 numbers (approx.)**: per-member external closures ≈
   `hello 0, agent 63,
   manager ~220, bridge ~221, wrecking ~208`; union ≈
   **367**; per-member sum ≈ **753** ⇒ ~**2.05×**; ~**1.88×** with the
   `agent ⊆ manager` chain. (Two measurement methods gave slightly different
   per-member sets — reconcile before quoting.) `agent ⊆ manager` is a closure
   relation.
7. **Pruned locks are `--offline`-safe** with the vendor dir as the pin;
   **pruned per-node vendors break chaining**.
8. **Layout-preserving `builtins.path` sources give identical store paths**;
   mirrors can be byte-identical to in-repo.
9. **No-IFD**, base drv stability across `.rs` content edits, and closure
   isolation were all verified empirically.

---

## 7. Current repository state

**Pvl `nix` (this repo).** Branch `master`, HEAD `0711cc31`
(`chore(hosts): add clippy to pvl-a1 and pvl-l5`), **ahead of `origin/master` by
10** (not pushed).

- The landed Rust build-graph work is in `origin/master` as `30a15c0a` (+
  `a0cd56c9`, `8d5ea4a1`, `40b17682`).
- Code touchpoints: `lib/flake/pkg-helper.nix`, root `Cargo.toml`,
  `pkgs/manifest.nix`, `pkgs/tools/abird-host-manager/default.nix`,
  `pkgs/tools/abird-host-agent/default.nix`, `docs/flake-package.md`.
- **Untracked (not committed) design docs**:
  `.agents/docs/plans/dual-mode-rust-build-graph-2026-09.md`,
  `.agents/docs/plans/g4-base-locality-2026-09.md`,
  `.agents/docs/plans/rust-build-graph-final-2026-09.md`,
  `.agents/docs/plans/multi-ecosystem-build-fabric-2026-09.md`,
  `.agents/docs/notes/tooling/rust-build-graph-dual-mode-goals-2026-09.md`,
  `.agents/docs/notes/tooling/rust-build-graph-g4-locality-2026-09.md`, and the
  council archive under `.agents/docs/notes/tooling/rust-build-graph-councils/`.
  (`.agents/docs/plans/design-f-build-graph-2026-09.md` is also untracked.)
- Working tree also has unrelated user edits under
  `pkgs/tools/abird-host-manager/`, `hosts/pvl-*` — **do not touch**.
- Scratch (may be cleaned): `tmp/design-f/`, `tmp/design-f2/`, `tmp/design-g4/`
  (raw council artifacts and experiments). Durable copies are under
  `.agents/docs/notes/tooling/rust-build-graph-councils/`.

**Abird (the `abird` remote), `/home/pvl/spaces/abird/src/z`.** Branch `master`,
HEAD `af41317a`, clean (`## master...origin/master`). This is the **24-member**
scale target: 804 packages, 44 workspace deps, 7 root-member path edges, 3
isolated workspaces, and a real Deno project. **Design L is not landed there
yet** (`lib/flake/pkg-helper.nix` has none of the DAG symbols), so the parity
port is a prerequisite. See
`.agents/docs/notes/tooling/rust-build-graph-abird-applicability-2026-09.md` for
the full mapping (closures, components, chaining edges, Tauri/overlay needs,
checklist).

---

## 8. Document map (reading order)

Read in this order (if you are working on **Abird**, also read
`.agents/docs/notes/tooling/rust-build-graph-abird-applicability-2026-09.md`
first; it maps every design onto Abird's 24-member shape):

1. **This handoff.**
2. `.agents/docs/notes/tooling/rust-build-graph-decision-2026-09.md` — decision
   log + measured residual + provenance.
3. `.agents/docs/plans/rust-workspace-build-graph-2026-09.md` — original L/F
   design and comparison.
4. `.agents/docs/plans/design-l-implementation-2026-09.md` — landed Design L
   work items.
5. `.agents/docs/notes/tooling/rust-build-graph-review-2026-09.md` — fresh
   review findings (P1/P2).
6. `.agents/docs/notes/tooling/cargo-workspace-2026-04.md` — corrected build
   contract note.
7. `.agents/docs/plans/design-f-build-graph-2026-09.md` — REWEAVE (superseded,
   kept for the adjudication).
8. `.agents/docs/notes/tooling/rust-build-graph-dual-mode-goals-2026-09.md` —
   G10/G11 goals.
9. `.agents/docs/plans/dual-mode-rust-build-graph-2026-09.md` — Design M.
10. `.agents/docs/notes/tooling/rust-build-graph-g4-locality-2026-09.md` — G4
    requirement + option space.
11. `.agents/docs/plans/g4-base-locality-2026-09.md` — Design G4 (supersedes
    Design M's base granularity).
12. `.agents/docs/plans/rust-build-graph-final-2026-09.md` — consolidated Rust
    design (best single overview).
13. `.agents/docs/plans/multi-ecosystem-build-fabric-2026-09.md` — the
    multi-ecosystem fabric.
14. `.agents/docs/notes/tooling/rust-build-graph-councils/` — raw council
    artifacts (research, candidate plans, critiques, finals) for all three
    councils.

Optional context:
`.agents/docs/notes/tooling/build-system-comparison-bazel-buck2-2026-09.md` (how
this design compares to Bazel and Buck2, and what to borrow), and
`.agents/docs/notes/tooling/rust-toolchain-contract-2026-09.md` (the four Rust
toolchain mechanisms our own projects use, and the per-capsule toolchain
contract + `craneLibFor` design).

Related pre-existing documents referenced by the councils:
`docs/flake-package.md`,
`.agents/docs/design-patterns/package-project-boundaries.md`,
`.agents/docs/design-patterns/shared-test-areas.md`,
`.agents/docs/design-patterns/external-source-units.md`,
`.agents/docs/notes/tooling/abird-post-3fc-port-2026-08.md`,
`.agents/docs/notes/tooling/shared-tooling-parity-2026-07.md`,
`.agents/docs/notes/tooling/repo-tooling.md`,
`.agents/docs/notes/tooling/abird-host-manager-fleet-dependency-audit-2026-09.md`.

---

## 9. Pending items / open questions

1. **Unit-DAG go/no-go spike (highest priority).** On stable cargo 1.95,
   offline, with the real lock: can a pinned producer emit exact per-unit
   descriptors for one capsule (package ids, resolved features, host/target
   roles, proc-macro/build-dep edges, build-script results), and do two capsules
   containing a shared registry crate produce **byte-identical unit
   derivations** while a divergent feature request produces distinct ones? If
   yes, the unit-DAG/Capsule-Ledger design is viable and strictly better on
   G4/G2/G10/G11; if no, fall back to Design G4 + Design M.
2. **Choose the Rust end state**: unit-DAG (Capsule/Ledger) vs G4
   closure-bases + M mirroring.
3. **24-member cost measurement** (mandatory before `member` becomes the
   default).
4. **G4 `.rs` add/remove wart**: adding/removing `src/bin/*`, `build.rs`, etc.
   invalidates `base(m)`; a manifest-only base is a deferred lever.
5. **Implement G4** (staged F0–F5 in the G4 doc) if chosen.
6. **Abird port/parity** (the two-repo contract; the `abird-post-*-port`
   process).
7. **`lib/flake` extraction** (Tier 1 vendoring; Tier 2 isolated flake, ~26
   `../..` sites + `service-module` split).
8. **Migrate the 13 child-flake wrappers** (they use relative imports and fall
   back to `rustPlatform.buildRustPackage`).
9. **Commit the untracked design docs** (or leave them for review).
10. **Push `master`** (ahead by 10) — awaiting explicit go-ahead.
11. **Fabric**: per-ecosystem producer-fidelity spikes (V9) and mode gate (V14);
    C++ tier/`native` policy; Python sdist policy; Deno native-addon capability.
12. **Reconcile the closure-sum discrepancy** (753 vs 712) before quoting costs.
13. Standing review findings P1-A/B/C, P2-a..h — fold into whichever design
    lands.

---

## 10. Councils and artifacts

| council | question                        | candidates                            | decision                  | durable artifacts                                                              |
| ------- | ------------------------------- | ------------------------------------- | ------------------------- | ------------------------------------------------------------------------------ |
| 1       | Design F (compile-once)         | F-union aggregate, F-cluster, REWEAVE | REWEAVE (later rejected)  | `plans/design-f-build-graph-2026-09.md`; `councils/council-1-design-f/`        |
| 2       | Dual-mode / mirroring (G10/G11) | L-KEEP, FACET, ECHO                   | Design M (MIRROR-L)       | `plans/dual-mode-rust-build-graph-2026-09.md`; `councils/council-2-dual-mode/` |
| 3       | G4 locality                     | KEYSTONE, DELTA-LATTICE, CLASSNODE    | Design G4 (CLOSURE-BASES) | `plans/g4-base-locality-2026-09.md`; `councils/council-3-g4/`                  |

---

## 11. Risks and non-guarantees

- **Producer fidelity** (unit-DAG): the whole design's correctness depends on
  capturing the ecosystem's own resolution; mitigated by fail-closed per-capsule
  modes.
- **Cost**: `member`/per-unit designs cost ~2× cold compiles vs a union; the win
  is locality, correctness and dedup.
- **Non-hermetic builds**: Python sdists, C++, Node `postinstall` — conditional;
  declared policy + `native` fallback.
- **`.rs` add/remove** invalidates `base(m)` (local).
- **One shared vendor** ⇒ lock/vendor churn is global (accepted).
- **Not guaranteed**: bit-identical binaries across different bases; standalone
  cache identity in `union` mode; `member` as the default before the 24-member
  measurement; cross-ecosystem identity across intentionally different pins.

---

## 12. Conventions used in this work

- Councils: researcher ∥ explorer → 3 staff engineers → critics → engineering
  manager; artifacts written to files and summarized.
- Docs live under `.agents/docs`; the top-level index is
  `.agents/docs/README.md` and must be updated when files change.
- Markdown is formatted with `deno fmt`.
- Do not commit/push without explicit instruction; ask before destructive git.
- Do not touch unrelated user changes.
