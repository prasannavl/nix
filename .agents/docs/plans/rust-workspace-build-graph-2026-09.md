# Rust Workspace Build Graph Handoff (2026-09)

Comprehensive handoff for the repo-wide Rust build/caching redesign. This plan
records the goals, current baseline, hard constraints, the near-term design
(**Design L**), the future end state (**Design F**), the comparison that chose
the staged path, the migration seams, and the validation gates.

Intent: implement **Design L** first, then move to **Design F** cleanly without
changing package definitions or the public helper API.

## Goals

- One repo-level Cargo workspace holding the common dependencies; each project
  adds its own dependencies (possibly reusing the common ones) and its source.
- Every dependency - in-repo workspace crate or external cargo crate - is
  compiled **once repo-wide**, not once per Nix package.
- During a project build, only the minimal change unit recompiles; maximize
  cache reuse.
- **No IFD** (import-from-derivation). This is a hard prerequisite, not a
  preference.
- Keep the existing repo structure and abstractions: per-package `default.nix`
  files, the `mkRustDerivation` API, `pkgs/manifest.nix` -> `packages.nix` ->
  `callPackage` composition, `checks`/`pkgOps`/`devShell`/`passthru` wiring.
- Optimize for the **repo state**: the plan is a pure function of the current
  manifests, `Cargo.lock`, toolchain, and target. A feature/manifest change may
  rewire the DAG to its new optimum; cross-state derivation-hash stability is
  explicitly not a goal.
- End state: a clean DAG factored by dependency **demand sets** (which projects
  need each unit), i.e. `deps-workspace`, `deps-pkg-<x>`, `deps-a`, ... then
  each project's own source.

## Non-goals

- Replacing crane, cargo, or the per-package helper API.
- Cross-feature-change hash stability or substituter reuse across unrelated
  commits.
- Changing the active Bash/Python `nixbot` runtime-input packaging (tracked
  separately in
  `.agents/docs/notes/tooling/abird-host-manager-fleet-dependency-audit-2026-09.md`).

## Current baseline

### Rust entry points in `lib/flake/pkg-helper.nix`

| Entry point                                 | Line   | Crane                | Used by                                                  |
| ------------------------------------------- | ------ | -------------------- | -------------------------------------------------------- |
| `mkRustDerivation`                          | `1977` | yes                  | all five workspace crates                                |
| `mkCraneRustPackage`                        | `1623` | yes                  | `pkgs/ext/stalwart-server`                               |
| `mkTrunkProject`                            | `1410` | yes                  | no current call sites                                    |
| `mkCargoWorkspacePackage`                   | `1727` | no                   | no current call sites (falls back to `buildRustPackage`) |
| `mkRustDerivation` with `projectDir = null` | `1977` | yes, already correct | `hello-rust-isolated`, `nestedRustPackage` test          |

Supporting pieces:

- `mkCargoWorkspaceSource` (`61`): filters the repo to `[projectDir] ++ deps`,
  materializes a `cargo-workspace-source` `runCommandLocal`.
- `cargoWorkspacePrePatch` (`121`): rewrites root `workspace.members` to
  `[projectDir] ++ deps`.
- `defaultCargoPackageArgs` (`33`) / `craneWorkspaceCargoArgs` (`37`): produce
  `--locked -p <pname>` and `--offline -p <pname>` for crane workspace builds.

### Workspace members and the one internal edge

`Cargo.toml` members: `pkgs/examples/hello-rust`,
`pkgs/support/nats-http-bridge`, `pkgs/tools/abird-host-agent`,
`pkgs/tools/abird-host-manager`, `pkgs/tools/nats-wrecking-ball`.

Internal path dependency: `abird-host-manager -> abird-host-agent`.
`pkgs/examples/hello-rust-isolated` is a separate single-crate workspace.

### Defects

1. **Per-package source filters.** `mkCargoWorkspaceSource` filters to
   `[projectDir] ++ deps`, so every crate gets its own `cargo-workspace-source`
   derivation.
2. **`dummySrc` is the real source.** `mkRustDerivation` sets
   `dummySrc = buildSrc` (`2136-2138`); `mkCraneRustPackage` sets
   `dummySrc = attrs.src` (`1684-1686`); `mkTrunkProject` sets
   `dummySrc = buildSrc` (`1581-1583`). Crane's `buildDepsOnly` honors an
   explicit `dummySrc` verbatim and uses it as the build `src` (it warns that
   `src` is ignored). The `-deps` derivation therefore compiles the real crate
   and depends on the whole source tree, defeating crane's cache separation.
3. **Per-package `cargoArtifacts`.** Each package runs its own `buildDepsOnly`,
   so every external crate is compiled once per Nix package.

### Observed evidence (2026-09-28)

- Four distinct `cargo-workspace-source` derivations and four distinct
  `*-deps-*.drv` derivations exist for the four workspace packages built through
  `mkRustDerivation` (`abird-host-manager`, `abird-host-agent`,
  `nats-http-bridge`, `nats-wrecking-ball`).
- `abird-host-manager-deps` shows `src = ...-cargo-workspace-source` (the real
  tree) and `buildPhase` running
  `cargo check --all-targets -p abird-host-manager` and
  `cargo build -p abird-host-manager`; `checkPhase` runs `cargo test --no-run`.
- Probe: appending two lines to `pkgs/tools/abird-host-manager/src/progress.rs`
  changed the `abird-host-manager-deps` derivation path
  (`83bf8cw33qzc2bgfg702s7rb3f033z0r-...` ->
  `z1bjbl0if60in4xi7hin27rdqx6k10kn-...`). Source edits invalidate the deps
  derivation today. The claim in
  `.agents/docs/notes/tooling/cargo-workspace-2026-04.md` that source edits keep
  the dependency artifact reusable is not what the derivations do.
- `vendorCargoDeps` is already shared: all packages use the same `Cargo.lock`,
  so there is a single vendor derivation. Sharing is missing only for compiled
  artifacts.

## No-IFD contract

IFD occurs when evaluation forces a store path (`builtins.readFile`, `readDir`,
`pathExists`, `import`, or hashing a path) on a **derivation**. In the Rust path
the traps are:

- `crateNameFromCargoToml` reading `<src>/Cargo.toml`. Avoided lazily by always
  passing `pname` and `version`.
- Crane's implicit `dummySrc = mkDummySrc args` reading `src`. Avoided by always
  passing an explicit `dummySrc` or a `builtins.path`-style source.
- `vendorCargoDeps` reading the lockfile. Avoided with `cargoLockContents` and
  an explicit `cargoVendorDir`.

Rules for every design in this plan:

1. `src` handed to `buildDepsOnly` is a **path** (eval-time readable) or an
   explicit `dummySrc` derivation; never a derivation used for crane's implicit
   source discovery.
2. Always pass `pname`, `version`, `cargoTomlContents`, `cargoLockContents`, and
   `cargoVendorDir`.
3. The planner reads only `Cargo.lock` and member `Cargo.toml` files, never a
   derivation.
4. Validation must run with IFD disabled (see Validation).

The current helper already satisfies most of this for `mkRustDerivation` (it
passes `pname`/`version` and `cargoLockContents`); the redesign must not regress
it and must extend it to the new deps sources.

## Dependency model (shared by L and F)

Definitions over the union package graph from `Cargo.lock` plus member
manifests:

- `seeds(m)`: direct normal, build, and dev dependencies of member `m`, with
  `{ workspace = true }` resolved from the root `[workspace.dependencies]`.
- `closure(m)`: transitive closure of `seeds(m)` over the lock adjacency.
  `Cargo.lock` is the workspace-union resolution, so lock-level closure is a
  safe over-approximation at package granularity; optional dependencies not
  enabled by any member may be pruned from the lock.
- `demand(p) = { m : p in closure(m) }`.
- Monotonicity: if `q -> p` then `demand(p) >= demand(q)`. This is what makes
  the DAG well-founded and acyclic.
- `roots(T)`: packages directly declared by members that use them and whose
  demand is exactly `T`. Grouping by direct declarations means the feature
  requests for a group's roots are known from the manifests.
- `groups(T) = closure of roots(T)`, i.e. all units whose demand is a superset
  of `T`.

## Design L - near-term (chosen)

Layered crane builds over one shared launderable source and one shared
dependency base. No generated stubs, no lock synthesis.

### Steps

1. **One laundered workspace source per repo revision.**
   - `workspaceRoot`: a `builtins.path` filter that keeps the root `Cargo.toml`,
     root `Cargo.lock`, every workspace member, and `.cargo` configuration.
   - `realSrc`: a `runCommandLocal` copy of `workspaceRoot`, named
     `cargo-workspace-source`, used by member layers.
   - The dependency base uses a path-based laundered source, or
     `craneLib.mkDummySrc` over `workspaceRoot`, so its derivation does not
     depend on `*.rs` content. No IFD either way.
   - `realSrc` and the dummy source share the `cargo-workspace-source` name so
     crane's `sourceName` relocation keeps fingerprint paths equal.
   - Drop the per-package source filter and the `deps`-based
     `cargoWorkspacePrePatch`; keep the full root member list in every
     derivation.

2. **One shared dependency base.**

   ```nix
   depsBase = craneLib.buildDepsOnly {
     src = launderedSource;                      # path or explicit dummySrc
     pname = "abird-rust-workspace-deps";
     cargoExtraArgs = "--offline " + memberArgs; # -p <member> ... for all members
     inherit cargoLockContents cargoVendorDir;
   };
   ```

   - An explicit `-p` list (rather than `--workspace`) keeps a platform-filtered
     member set possible.
   - `doCheck = true` (crane default) caches dev-dependencies; carry the union
     of per-crate `nativeCheckInputs` in the base if used.

3. **Member layers.**

   ```nix
   memberLayer(m) = craneLib.buildPackage {
     src = realSrc;
     cargoArtifacts = join ([prefixNode m] ++ map memberLayer (internalDeps m));
     pname = m;
     cargoExtraArgs = "--offline -p ${m}";
     doInstallCargoArtifacts = true;
     doCheck = false;
   };
   ```

   - `prefixNode(m)` is the nearest base/chain node whose artifact set covers
     `m`'s external units. In L this is always `depsBase`.
   - `join` is the crane `.prev` join: a symlink-only derivation producing
     `$out/target.tar.zst` -> parent A and `$out/target.tar.zst.prev` -> parent
     B, recursively. `inheritCargoArtifacts` already recurses `.prev`, so no
     target-dir copying is needed.

4. **Checks.**
   - `checks.lint` is `cargoClippy` with `cargoArtifacts = memberLayer(m)` and
     `cargoExtraArgs = "-p <m>"`.
   - `checks.test` is `cargoTest` with the same artifacts and `doCheck = true`.
   - `checks.fmt` needs no artifacts.
   - Keep `buildAttrs.doCheck = false` on packages that deliberately do not run
     tests in the package build; the separate `checks.test` remains the gate.

### Feature handling in L

A single union base built with `-p` all members resolves shared dependencies
with the workspace-union feature set. A member layer built with `-p <m>`
resolves a subset, and cargo recompiles subset-feature units. Two options:

- **Normalize features** in `[workspace.dependencies]` (declare the feature set
  once, reference bare in members). Recommended for L; keeps base == layer
  resolution and avoids recompiles.
- **Sub-option L'**: skip the union base and build per-project deps layers in a
  fixed order (`depsOnly`/`mkCargoDerivation` with `-p <m>`, each inheriting the
  previous). This avoids normalization (each layer resolves `-p <m>` exactly) at
  the cost of a linear chain and coarser dep locality. Treat as a fallback if
  normalization is undesirable.

### L properties

- Every external unit compiled once (base), every workspace crate compiled once
  (member chain + internal joins).
- `.rs` edits never touch `depsBase` (laundered dummy source).
- `.rs` edit to `m` invalidates `memberLayer(m)` and its dependents only.
- A dependency manifest/lock change rebuilds `depsBase` and recompiles the full
  external set; this is L's known weakness and the reason to move to F.

## Design F - future end state

Demand-factored dependency DAG. Same model, finer factoring.

### Planner (pure eval)

Inputs: repo root, root `Cargo.toml`, member manifests, `Cargo.lock`. Output:

```text
{
  sources;      # workspaceRoot path + realSrc spec
  groups;       # [{ key = <sorted member list>, label, roots, parents }]
  members;      # [{ name, dir, directDecls, internalDeps }]
  chainOrder;   # groups ordered by decreasing |demand|
}
```

- Build the package graph and demand sets per the model above.
- Group by demand; keep non-empty groups.
- `parents(T)` = maximal proper supersets of `T` that are non-empty groups.
- `chainOrder` orders groups by decreasing `|demand|` (a total chain is the
  simplest realization; the superset DAG is an optional refinement).

### Emitter

- `realSrc`: as in L.
- `depsSrc`: a `runCommandLocal "cargo-workspace-source"` assembling
  - a generated root `Cargo.toml` whose members are the generated stub crates,
  - one stub crate per group: `Cargo.toml` with
    `root = { version = "=x.y.z", features = <union over group members> }` and
    an empty `src/lib.rs`,
  - `Cargo.lock` (real lock plus generated stub entries, or offline
    re-resolution inside the sandbox).
- Group layers:

  ```nix
  groupLayer(T) = craneLib.mkCargoDerivation {
    src = depsSrc;
    cargoArtifacts = join (map groupLayer (parents T));
    cargoExtraArgs = "--offline -p crane-group-${label T}";
    doCheck = false;
    doInstallCargoArtifacts = true;
  };
  ```

  `buildDepsOnly` hard-codes `cargoArtifacts = null`, so groups use
  `mkCargoDerivation` (or `buildPackage` with `doCheck = false`) directly.
- `memberLayer(m)` = as in L, with `prefixNode(m)` being the chain node at the
  maximum `chainOrder` index among the groups that contain `m`.
- Checks unchanged.

### Feature handling in F

- Stub roots are direct declarations, so the group's root features are the union
  of the members' declared features. Every member's need is a subset of the
  union, so shared units match and no normalization is required.
- `default-features = false` conflicts cannot be represented by one unit; the
  planner keys that group dimension separately (package plus default-feature
  polarity) if it occurs. No current member triggers this for a shared crate.

### F properties

- Every external unit compiled once, in the group keyed by its demand.
- A dependency change rebuilds the affected group and the later chain nodes;
  inherited common units are reused rather than recompiled.
- A source edit to `m` invalidates `memberLayer(m)` and its dependents only.
- Rewire-on-change is accepted: any manifest/lock/toolchain edit re-derives the
  plan and re-orders groups. Correctness is preserved because a member's real
  build still resolves its own closure and will compile anything missing.
- Store cost stays near one target dir because crane installs `.prev` deltas.

### Known limits of F without IFD

- Demand sets are computed from `Cargo.lock` (package granularity). A transitive
  package whose demand set has no direct declaration may be reached through
  multiple roots and compiled in whichever chain node first contains it rather
  than a shared node. Correct, occasionally suboptimal.
- Exact unit-level factoring and transitive feature resolution would require IFD
  (`cargo metadata` / `cargo tree` in a derivation), which is ruled out. Accept
  the approximation; it self-corrects whenever the plan is recomputed.

## Comparison

| Dimension                | Design L (near-term)                             | Design F (end state)                                                          |
| ------------------------ | ------------------------------------------------ | ----------------------------------------------------------------------------- |
| Derivations              | 1 source + 1 base + N layers                     | 1 real source + 1 deps source + G groups + N layers                           |
| Every unit compiled once | yes (base)                                       | yes (chain inheritance)                                                       |
| No IFD                   | yes                                              | yes                                                                           |
| Feature normalization    | required for a union base (or use sub-option L') | not required; stub declares the union per group                               |
| Dep-manifest change      | base rebuilds -> all externals recompile         | only the affected group and later chain nodes                                 |
| Source change locality   | edited member layer + dependents                 | same                                                                          |
| Complexity               | low: uses crane as intended                      | medium-high: planner, stub synthesis, lock handling, joins                    |
| Debuggability            | high (flat, legible plan)                        | lower (generated workspace)                                                   |
| Failure modes            | lock/vendor drift                                | + synthetic-workspace resolution, stub feature drift, default-features splits |
| Cargo-version resilience | high                                             | medium                                                                        |
| Cross-commit cache       | worse on dep churn, good on unrelated edits      | better on dep churn                                                           |

### Why L first

- L already delivers the dominant win: `.rs` edits (the common case) never
  rebuild dependencies, and each crate/dependency compiles once.
- L uses one mechanism (crane layering) with no generated code, no synthetic
  workspace, and no lock synthesis.
- F's marginal gain appears on dependency-manifest churn and remote-cache
  isolation, which are rarer and can be added behind the same seams.

### Why F eventually

- Dep changes stop recompiling the full external set.
- Every derivation is minimal and self-describing (`deps-<AB>`, `deps-<A>`).

## Migration path L -> F

Keep the public API and packaging unchanged throughout.

1. **L0 - dummy source fix.** Add the path-based laundered source and explicit
   `dummySrc`; stop passing the real source as `dummySrc` at `2136-2138`,
   `1684-1686`, and `1581-1583`. Assert `-deps` derivation hash is invariant
   under a `.rs` edit. This is the single highest-value change.
2. **L1 - shared source + shared base + member layers.** Whole-workspace source,
   one `depsBase`, member layers with `.prev` joins for internal deps, checks
   consuming member layers. Optionally normalize features.
3. **L2 - planner diagnostic.** Implement the pure-eval planner and expose it as
   a diagnostic output (for example `rustPlan`) that prints demand sets and
   group structure. No build-system change; validates the model against the real
   lock.
4. **F - promote planner to groups.** Replace the single base with the ordered
   group chain, add `depsSrc` with generated stubs, and point member layers at
   the chain node that covers them. Optionally start with 2-3 hand-declared
   groups (common / nats ecosystem / manager extras) before going fully
   automatic; the layer/join mechanics are identical.

Seams to preserve so L -> F is mechanical:

- source injection point (`dummySrc`/`src`),
- `cargoArtifacts` injection point (`prefixNode`),
- a group label/identifier even in L (single group at first),
- `checks`/`pkgOps`/`devShell`/`passthru` wiring untouched.

## Validation

- **No-IFD gate:** evaluation and build succeed with IFD disabled, for example
  `nix eval --option allow-import-from-derivation false
  .#abird-host-manager.drvPath`
  (and the same for every workspace package).
- **Source invariance:** the `-deps` (or group) derivation path is byte-stable
  across a `.rs` edit. Use `nix derivation show -r` before/after and compare.
- **Minimal recompile:** after a real edit, the build log contains only the
  expected `Compiling <crate>` lines; `nix build --dry-run` shows only the
  affected layers.
- **Sharing:** count distinct `cargo-workspace-source` and deps derivations
  across the workspace packages. Target: 1 source and 1 base for L; 1 real
  source, 1 deps source, and G groups for F.
- **Correctness:** `cargo test -p abird-host-manager`, `-p abird-host-agent`,
  plus `nix flake check` for the affected checks.
- **Closure size:** `nix path-info -S` before/after; expect no regression and
  usually a shrink as duplicates disappear.
- **DAG shape for F:** `nix derivation show -r` shows the expected group
  inheritance edges and no cycles.

## Decisions

- Adopt **L** now, then **F** later, behind stable seams.
- **No IFD** is a hard prerequisite; the planner is pure eval or absent.
- Optimize for repo state; rewiring on feature/manifest change is acceptable.
- Reuse crane's `.prev` mechanism for multi-parent artifact joins.
- Keep `mkRustDerivation` as the public entry point; plans are computed
  internally keyed on the repo root.

## Open questions

- Normalize `[workspace.dependencies]` features for L, or take sub-option L'
  (per-project deps chain) and skip normalization?
- Full automatic grouping at F, or start with 2-3 hand-declared groups?
- Lock handling for F stubs: synthesize stub entries into `cargoLockContents`,
  or let group builds re-resolve `--offline` against the vendor dir?
- Platform gating: how to filter members/groups per `hostPlatform` so a
  Darwin-incompatible member cannot break unrelated groups.
- Where the planner lives: inside `pkg-helper.nix`, or a new
  `lib/flake/rust-workspace.nix` consumed by it.
- Whether to also fix `mkTrunkProject` and `mkCraneRustPackage` in L0 (same
  `dummySrc` defect) or track them separately.

## References

- `lib/flake/pkg-helper.nix`: `mkCargoWorkspaceSource` (`61`),
  `cargoWorkspacePrePatch` (`121`), `mkTrunkProject` (`1410`),
  `mkCraneRustPackage` (`1623`), `mkCargoWorkspacePackage` (`1727`),
  `mkRustDerivation` (`1977`).
- `Cargo.toml` / `Cargo.lock`: workspace members, shared dependency versions,
  single dependency source of truth.
- Package definitions: `pkgs/tools/abird-host-manager/default.nix`,
  `pkgs/tools/abird-host-agent/default.nix`,
  `pkgs/support/nats-http-bridge/default.nix`,
  `pkgs/tools/nats-wrecking-ball/default.nix`,
  `pkgs/examples/hello-rust/default.nix`,
  `pkgs/examples/hello-rust-isolated/default.nix`.
- `.agents/docs/notes/tooling/cargo-workspace-2026-04.md`: current build
  contract; its dependency-reuse claim is superseded by the evidence above.
- `.agents/docs/notes/nixbot/rust-host-manager-replacement-2026-09.md`: Rust
  host-manager context and cutover boundary.
- `.agents/docs/notes/tooling/abird-host-manager-fleet-dependency-audit-2026-09.md`:
  runtime-input dependency audit, separate from this build-graph work.
