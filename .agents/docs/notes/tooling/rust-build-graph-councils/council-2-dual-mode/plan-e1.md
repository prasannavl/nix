# Design F2 / Council 2 — Candidate E1: **L-KEEP**

**L-Evolution: keep landed L, add a base seam, a component base, an
external-package seam, and layout-preserving mirrors.**

Status: implementation-ready plan (council 2, candidate E1). Scope: Rust
workspace packages under `pkgs/**` and the shared library `lib/flake`. Relation
to prior art:

- **Builds on landed L**
  (`.agents/docs/plans/design-l-implementation-2026-09.md`): `--offline -p <m>`
  member resolution over a component-filtered source with the root `members`
  list rewritten (`lib/flake/pkg-helper.nix:33,37,102,235,2261,2290,2400`).
- **Rejects REWEAVE** (`.agents/docs/plans/design-f-build-graph-2026-09.md`):
  its union manifest rewrite makes a member's effective features a function of
  monorepo peers, which is disqualifying under G10/G11.
- **Adopts the measured facts** from `tmp/design-f2/research.md`.

---

## 0. Decision (one paragraph)

Keep landed L's per-member `-p m` semantics and **change the unit of cache
sharing, not the unit of resolution**. Introduce a first-class **component
dependency base**: one `buildDepsOnly` per path-connected Cargo component, used
by every member of that component. Add a `base ? null` seam so any package can
accept an externally supplied dependency base while still being able to build
its own. Add an `externalPackagesFor` seam so a mirror flake's package can
replace an in-repo package by name. Define mirrors as **layout-preserving
component repos** (same monorepo-relative paths, byte-copied root `Cargo.toml`
and `Cargo.lock`), generated from `Cargo.toml`/`Cargo.lock`, with CI gates that
prove `mirror drv == member drv` and check drift. No IFD, no manifest rewrite,
no union widening, no per-package hand-sync.

---

## 1. Goals restated against this design

| goal                                      | mechanism                                                                                                                                                                               |
| ----------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| No IFD                                    | component/mirror metadata is read from evaluator-visible paths only (`fromTOML`/`readFile`/`readDir`); no derivation is realised at eval                                                |
| Correctness first                         | L's `-p m` resolution is untouched; each member resolves its own canonical requirements                                                                                                 |
| Scale to 24 members                       | sharing is per component, not per repo; components are independent; the base seam bounds worst-case cost                                                                                |
| Simple consumption API                    | `mkRustDerivation { projectDir; base ? null; baseStrategy ? "component"; … }`; package flakes expose `packages.<system>.<name>` and `lib.<system>.mkPackage { pkgs; base ? null; }`     |
| Low churn                                 | mirrors are generated; `default.nix` needs no per-package edit; drift is a gate                                                                                                         |
| Compile each dep as few times as possible | component base (once per component) + L's internal-dep layer chain; union base opt-in                                                                                                   |
| `.rs` edits local                         | base is dummy-sourced (manifests/lock only); only the edited member and its dependents rebuild                                                                                          |
| **G10 dual mode**                         | component-scoped, mirror-identical base + layout-preserving mirrors + optional `lib/flake` extraction                                                                                   |
| **G11 seamless replacement**              | `externalPackagesFor` name swap + `mkPackage { pkgs; base }` injection; in component mode the mirror drv is **bit-identical** to the member drv, so the cache is shared by hash-consing |

---

## 2. Why L is already most of the way there

Landed L already builds every workspace member package-locally:

- `defaultCargoPackageArgs` (`:33`) emits `--locked [-p m]`.
- `craneWorkspaceCargoArgs` (`:37`) removes `--locked` for workspace members and
  prepends `--offline`, so a member runs `cargo … --offline -p m`.
- `resolvedCraneBuildCargoArgs` (`:2290`) and `memberLayer` (`:2400`) use it.
- `mkCargoWorkspaceSource` (`:102`) and `cargoWorkspacePrePatch` (`:235`) filter
  the source to `[projectDir] ++ deps` and rewrite the root `members`.

So a member's feature/version resolution already depends only on its component
manifests and the single `Cargo.lock`. The union `sharedDepsBase` is only a
**cache hint**: a mismatch makes cargo recompile, it never changes the binary.
L-KEEP keeps exactly this and does not introduce any manifest rewrite.

The only monorepo-global inputs are `Cargo.lock` and `[workspace.dependencies]`.
Both are copied verbatim into mirrors, so mirrors reproduce the member's
resolution byte-for-byte.

---

## 3. Architecture

```text
                          pure eval (no IFD)                         build time
root Cargo.toml + member Cargo.toml + Cargo.lock
       │
       ▼
lib/flake/rust-components.nix   (new, pure, ~100 lines)
├─ members (glob-expanded)                                  ┌───────────────────────────┐
├─ per-member path-dep edges                                 │ componentBase(C)          │
└─ path-connected components C                                │  buildDepsOnly:           │
       │                                                      │   dummySrc(C dirs)        │
       ▼                                                      │   root-members := C dirs  │
lib/flake/pkg-helper.nix  (evolved emitter)                   │   --offline --workspace   │
├─ baseStrategy ∈ {component, union, external, local}         │   lock + vendor           │
├─ base ? null  (external seam)                               └────────────┬──────────────┘
├─ prefixNode = base | componentBase | unionBase | packageBase            │ cargoArtifacts
└─ memberLayer(m): src=buildSrc(m), -p m, doInstallArtifacts  ┌───────────▼──────────────┐
       │                                                      │ memberLayer(m)            │
       ▼                                                      │  + internalDeps layers    │
lib/flake/packages.nix  (+ externalPackagesFor seam)          └───────────────────────────┘
       │
       ▼
flake outputs ── externalPackagesFor ──► mirror lib.mkPackage { pkgs; base }
```

Two new pure/mechanical pieces, everything else is a delta to existing code:

1. **`lib/flake/rust-components.nix`** — path-connected components from
   `Cargo.toml` path deps. Data only; no `pkgs`, no crane.
2. **`lib/flake/component-outputs.nix`** — a small mirror flake assembly helper.

---

## 4. Exact API

### 4.1 `pkg-helper.nix` becomes a function (one-time mechanical conversion)

The four relative-path escapes (research §2.1) and the need to inject a default
base are the same problem: the helper needs to be instantiated with its repo
root. Convert the top of the file:

```nix
{ # new, all defaulted to today's behaviour
  repoRoot ? null,          # :11   builtins.toString (if repoRoot != null then repoRoot else ../..)
  defaultSrc ? null,        # :1529/:2116   default `src` for mkTrunkProject / mkRustDerivation
  treefmtConfig ? null,     # :474   default `../../treefmt.toml`
  defaultBase ? null,       # base used when a call does not pass one (see 4.2)
}: let
  resolvedRepoRoot = builtins.toString (if repoRoot != null then repoRoot else ../..);
  ...
```

- `repoFmtCheckCommand` uses
  `if treefmtConfig != null then treefmtConfig else ../../treefmt.toml`.
- Both default `src = …` sites use
  `if defaultSrc != null then defaultSrc else ../..`.
- The returned attrset is byte-for-byte the current public surface
  (`mkRustDerivation`, `mkTrunkProject`, `mkStdFlakeOutputs`,
  `mkPackageOpsBundle`, `mkNixosModuleAttrs`, …).

Call sites change mechanically from `import …/pkg-helper.nix` to
`import …/pkg-helper.nix {}` (12 known sites: `lib/flake/default.nix:24`,
`lib/flake/stack/lib.nix:38`, `lib/flake/stack/package.nix:2`,
`lib/flake/tests/default.nix:43`, and seven `pkgs/**/default.nix` defaults plus
`pkgs/cloudflare-apps/*`). One token per site; no semantics change.

### 4.2 `mkRustDerivation` public delta

Everything current stays. New optional arguments:

```nix
pkgHelper.mkRustDerivation {
  pkgs;
  projectDir;                  # unchanged: monorepo-relative, preserved in mirrors
  deps ? [];                   # unchanged
  internalDeps ? [];           # unchanged

  # --- new -----------------------------------------------------------------
  base ? defaultBase,          # derivation | null: externally supplied dependency artifacts
  baseStrategy ? "component",  # "component" | "union" | "local" | "external"
  component ? null,            # optional precomputed component dir list (pure-eval injection)
  mirrorUnit ? null,           # optional metadata for diagnostics / passthru
  # -------------------------------------------------------------------------
  ...
}
```

Semantics of the dependency prefix (`prefixNode`), preserving L elsewhere:

```nix
prefixNode =
  if base != null            then base                       # external seam wins
  else if baseStrategy == "external" then (throw "baseStrategy=external requires base")
  else if baseStrategy == "union"    then sharedDepsBase     # L's current workspace base
  else if baseStrategy == "local"    then packageCargoArtifacts  # L's per-package base
  else                                    componentBase;       # "component" (default)
```

- `componentBase` = `buildDepsOnly` over the path-connected component containing
  `projectDir`, computed by `rust-components.nix` unless `component` is
  supplied. It is **canonical**: identical `componentDir` bytes ⇒ identical
  derivation.
- `sharedDepsBase` and `packageCargoArtifacts` are unchanged from L.
- `dependencyArtifacts` keeps L's rule: internal-dep member layers when present,
  otherwise `prefixNode`, with `mkCargoArtifactsJoin` for fan-in. This preserves
  `.rs` locality and dedup for multi-crate components.
- `base` may also carry a _different_ base for a consumer who wants union speed;
  cargo recompiles what is missing; the binary is unchanged.

New passthru (additive):

```nix
passthru = {
  baseStrategy;      # resolved strategy actually used
  depsBase;          # the chosen prefixNode (componentBase | unionBase | base | packageBase)
  componentDirs;     # canonical component dir list (null for non-workspace/legacy)
  mirrorUnit;        # component metadata when known
  memberLayer;       # unchanged (present in workspace mode)
  sharedDepsBase;    # unchanged
  ...
};
```

### 4.3 Pure component reader — `lib/flake/rust-components.nix`

```nix
{ lib }:
{
  # -> [ "pkgs/tools/abird-host-agent" ... ] (glob-expanded, canonicalised)
  members = src: ...;
  # -> [ dirs ] the path-connected component containing `dir`
  componentOf = src: dir: ...;
  # -> { <componentKey> = { dirs; members; }; } deterministic
  components = src: ...;
}
```

- Reads `src/Cargo.toml` `[workspace].members` (expands simple `*`/`?` globs
  with `readDir` + `match`) and each member's `Cargo.toml` dependency tables,
  keeping entries with `path`.
- Resolves each path lexically (`dir/../rel`) and keeps only paths that are
  workspace members; builds an **undirected** adjacency; takes connected
  components (so `manager -> agent` puts both in one component even though agent
  does not depend on manager).
- Deterministic ordering everywhere (sorted dirs).
- **Degradation, never throw:** any parse/glob failure returns
  `componentOf = _: _: null`, and `mkRustDerivation` falls back to
  `[projectDir] ++ resolvedDeps` with a `lib.warn`. No IFD.

### 4.4 Composition seam — `externalPackagesFor`

Thread a defaulted argument:
`flake.nix → lib/flake/root.nix → lib/flake/default.nix → withPkgs → lib/flake/packages.nix`.

In `flake.nix`:

```nix
inputs.abird-host-agent.url = "github:OWNER/abird-host-agent";
inputs.abird-host-agent.inputs.nixpkgs.follows = "nixpkgs";
inputs.abird-host-agent.inputs.crane.follows  = "crane";

outputs = inputs: (import ./lib/flake/root.nix {
  inherit inputs;
  externalPackagesFor = system: {
    # value is either a derivation (semantics-only swap) or a function
    # { pkgs, base ? null }: derivation (shares the monorepo base).
    abird-host-agent =
      { pkgs, base ? null }:
      inputs.abird-host-agent.lib.${system}.mkPackage { inherit pkgs base; };
  };
  ...
}).outputs;
```

In `lib/flake/packages.nix`:

```nix
packagesFn { pkgs, externalPackagesFor ? _: {}, pkgHelper ? …, src ? … }: let
  externalPackages = externalPackagesFor pkgs.stdenv.hostPlatform.system;
  canonicalPackages = builtins.mapAttrs (name: entry:
    if externalPackages ? ${name}
    then
      let e = externalPackages.${name}; in
      if builtins.isFunction e then e { inherit pkgs; base = null; } else e
    else pkgs.callPackage entry.path (…) ) validatedEntries;
in …
```

- Replacement is **by manifest name**, so `abird-host-manager`'s
  `entry.args = packages: { abirdHostAgent = packages.abird-host-agent; }`
  automatically receives the external agent (or the in-repo one). Aliases and
  `toolingPackages`/`rootApps` continue to resolve.
- The composition can offer a base by passing it into the function form
  (`self.packages.${system}.rust-workspace-deps`, see 4.5).
- If an external entry fails to evaluate, `isAvailablePackage` already drops it
  and the in-repo package remains (graceful degradation). A `lib.warn` names the
  fallback.

### 4.5 Union base as an output (for optional G11 sharing)

`withPkgs` exposes the monorepo union base once:

```nix
packages.rust-workspace-deps = pkgHelper.mkSharedRustDepsBase { … };
```

so `flake.nix` can write `base = self.packages.${system}.rust-workspace-deps;`
when it wants max dedup instead of component-identical drvs. This is the only
new public artifact name; it can be hidden under `legacyPackages`/`_` if
desired.

### 4.6 Package-flake output contract (what a mirror must expose)

A mirror flake MUST expose:

```nix
packages.<system>.<name>      # standalone build (component base), each component package
packages.<system>.default     # primary package of the component
lib.<system>.mkPackage        # { pkgs, base ? null }: derivation   ← G11 replacement/seam
lib.<system>.depsBase         # the component base derivation       ← cache sharing
lib.<system>.component        # { dirs; members; packages; }        ← drift/parity metadata
nixosModules.<name>           # unchanged, when the package provides one
```

`mkPackage` MUST accept the consumer's `pkgs` (so the gate and the monorepo can
eliminate nixpkgs/crane drift) and MUST expose the same `passthru` subset as the
in-repo package (`memberLayer`, `projectDir`, `sharedDepsBase`, `depsBase`,
`checks`, `fmt`, `lint-fix`). This is the interface L's `internalDeps` guard
already expects (`pkg-helper.nix:2380-2400`).

---

## 5. Emitter mechanics and cargo invocations

### 5.1 Component base (`baseStrategy = "component"`)

```nix
componentSource = mkWorkspaceSourcePath {
  inherit src; selectedDirs = componentDirs; name = "cargo-workspace-source";
};
componentBase = pkgs.craneLib.buildDepsOnly {
  dummySrc   = pkgs.craneLib.mkDummySrc { src = componentSource; };
  pname      = "abird-rust-${componentKey}";
  version    = "0.1.0";
  cargoExtraArgs = "--offline --workspace";
  prePatch   = cargoWorkspaceMembersPrePatch { members = componentDirs; };
  inherit (resolvedCraneCargoLockAttrs) cargoLockContents;
  cargoVendorDir = craneCargoVendorDir;
  # profile inputs for the component (see §9)
};
```

- `--offline --workspace` over the component; no `--locked` (matches L's
  `mkSharedRustDepsBase`).
- `buildDepsOnly` runs `cargo check --all-targets`, `cargo build`,
  `cargo test --no-run`, priming normal/build/dev/test/bench units.
- The dummy source is manifest/lock-only, so `.rs` edits never invalidate it.
- `cargoWorkspaceMembersPrePatch` is the non-`projectDir` variant of the
  existing `cargoWorkspacePrePatch` (`:235`); factor the awk out and reuse.
- `componentSource` is filtered from the same `src` and uses the load-bearing
  name `cargo-workspace-source`, so it unpacks to
  `/build/cargo-workspace-source` exactly like member sources (fingerprint
  alignment).

### 5.2 Member layer (unchanged from L)

```nix
memberLayer = craneLib.cargoBuild (craneCommonAttrs // {
  src        = buildSrc;                       # mkCargoWorkspaceSource [projectDir]++deps
  prePatch   = buildPrePatch;                  # root members := component dirs
  cargoArtifacts = dependencyArtifacts;        # internal layers | prefixNode | join
  cargoExtraArgs = shellWords resolvedCraneBuildCargoArgs;  # "--offline -p m"
  doInstallCargoArtifacts = true;
});
```

`buildPackage` inherits `memberLayer` exactly as today (`:2467`), so the
deployed derivation does not export artifacts.

### 5.3 Mirror build

The mirror uses the **same** `default.nix` and the **same** helper path
(`lib/flake/pkg-helper.nix` at the same relative location), so the emitter code
path is identical. The mirror flake's `mkComponentFlakeOutputs`:

1. filters `pkgs/manifest.nix` to the component's packages (generated file);
2. instantiates `pkgHelper` with `{ repoRoot = ./.; defaultSrc = ./.; }`;
3. calls `packagesFn { inherit pkgs; pkgHelper; src = ./.; }` (no
   `externalPackagesFor`);
4. returns `packages`, `checks`, `nixosModules`, and
   `lib.<system>.mkPackage/lib.depsBase`.

### 5.4 Exact drv-identity conditions

`mirror(m).drvPath == member(m).drvPath` iff all of:

1. **Source bytes equal**: same component dirs at the same monorepo-relative
   paths, same root `Cargo.toml` bytes, same `Cargo.lock` bytes, same `.cargo`.
   This is why mirrors are **layout-preserving**.
2. Same `prePatch` text (same component dirs) and same `cargoExtraArgs`.
3. Same `prefixNode` (component base) or same injected `base` drv.
4. Same `pkgs` (nixpkgs + craneLib). The parity gate instantiates the mirror's
   `mkPackage { pkgs = monorepoPkgs; }` to guarantee this; production mirrors
   use `follows` to align nixpkgs and crane.
5. Same `nativeCheckInputs`/`buildAttrs` (same `default.nix`, same `pkgs`).
6. Same vendor derivation (identical `Cargo.lock` text ⇒ identical
   `vendorCargoDeps`, research §4.4).

Path-dep entries inside member manifests stay verbatim (`../abird-host-agent`),
so they keep resolving because the layout is preserved.

---

## 6. Base strategy semantics and the sharing story

| strategy                          | base source                                          | mirror-identical | cost                                                      | use                                           |
| --------------------------------- | ---------------------------------------------------- | ---------------- | --------------------------------------------------------- | --------------------------------------------- |
| **`component`** (package default) | `buildDepsOnly` over the path-connected component    | **yes**          | ~Plan B; measured ≈753 vs union 367 at 5 members (≈2.05×) | G10/G11 default; standalone                   |
| **`union`**                       | L's `sharedDepsBase`, whole workspace, `--workspace` | no               | measured 367                                              | monorepo max-dedup                            |
| **`external`** (`base` set)       | caller-supplied                                      | depends          | caller's                                                  | inject union base into a mirror; hybrid speed |
| **`local`**                       | L's `packageCargoArtifacts`, `[projectDir]++deps`    | yes              | ≤ component (more bases)                                  | L bit-for-bit rollback; non-member fallback   |

**Sharing story, precisely:**

- In `component` mode the monorepo member and the standalone mirror compute the
  **same component base drv** and the **same memberLayer drv**. Nix hash-conses
  them; publishing either repo's cache satisfies the other with no seam and no
  IFD. This is the strongest form of G11.
- In `union` mode the base is monorepo-only. G11 still gets exact identity when
  the monorepo builds the mirror through
  `mkPackage { pkgs; base = unionBase; }`: source and every other input are
  identical, so the resulting package drv is identical to the in-repo one. The
  mirror's own standalone drv (component base) is a _different but semantically
  equivalent_ build of the same crate — cargo recompiles from the injected base;
  the binary is unchanged.
- The residual under both modes is bounded to in-component shared crates
  (research §3.3/§3.5): singleton components resolve identically to their base,
  so residual is zero; only multi-crate components (today `{agent, manager}`)
  can recompile a shared dep in a member layer. `local` mode removes even that
  at more bases. No correctness depends on this; it is a compile-count knob.

**Default stance:** `mkRustDerivation` defaults to `component` so mirrors are
standalone-identical. The monorepo composition keeps `union` during migration
(zero regression), then flips components to `component` as mirrors land. This is
the only honest way to satisfy "component default" and "no regression" at once.

---

## 7. G10 — dual mode, satisfied and proven

### 7.1 (a) Monorepo

Unchanged path:
`flake.nix → root.nix → default.nix → packages.nix →
callPackage default.nix → mkRustDerivation`.
`baseStrategy = "union"` until a component is migrated, then `"component"`. All
existing behavior preserved.

### 7.2 (b) Standalone mirror

A mirror repo at `mirrors/<unit>/` contains:

```text
Cargo.toml              # byte copy of monorepo root Cargo.toml
Cargo.lock              # byte copy of monorepo Cargo.lock
.flake/ or flake.lock   # generated/pinned by the mirror flake
flake.nix               # generated, ~15 lines, calls component-outputs
lib/flake/**            # Tier 1: byte-identical vendored helper (or Tier 2 input)
pkgs/manifest.nix       # generated, component-filtered manifest
pkgs/<component dirs>   # byte copy, same relative paths
treefmt.toml            # byte copy (fmt checks)
```

It evaluates and builds with no monorepo checkout:
`nix build .#packages.<system>.default`. Because paths are preserved,
`default.nix` and its helper import `../../../lib/flake/pkg-helper.nix` are
unchanged.

### 7.3 G10 proof (gate `mirror-parity`, §11)

For every component package `m`:
`mirror.lib.${system}.mkPackage { pkgs = monorepoPkgs; base = null; }.drvPath
 == monorepo.packages.${system}.${m}.drvPath`.
This proves G10(b) is not a loose re-implementation: the standalone build is the
same derivation. Plus `nix flake check` on the mirror and
`--option allow-import-from-derivation false` on both.

---

## 8. G11 — seamless replacement, satisfied and proven

### 8.1 Mechanism

1. `externalPackagesFor` swaps any manifest package by name (4.4).
2. The mirror exposes `lib.mkPackage { pkgs; base }`; the monorepo passes its
   own `pkgs` and optionally its union base.
3. Downstream in-repo packages that took the replaced package as `internalDeps`
   receive the external drv automatically through `entry.args`; its
   `passthru.memberLayer`/`projectDir` satisfy the existing guard, so manager
   inherits the external agent's layer.

### 8.2 Exact gates

- **GATE-M (mirror == member).**
  `drvPath(mirror.mkPackage { pkgs; base = null }) == drvPath(member)` in
  component mode; and
  `drvPath(mirror.mkPackage { pkgs; base = member.sharedDepsBase }) ==
  drvPath(member)`
  in union mode.
- **GATE-B (base identity).**
  `mirror.lib.${system}.depsBase.drvPath == member.passthru.depsBase.drvPath` in
  component mode.
- **GATE-S (semantics, union standalone).** When only the union base differs,
  assert equal `cargo tree -e features --offline -p m` feature sets for the
  packages with explicit `default-features = false`, and equal `pname`, bin
  names, and lock. (Weaker than GATE-M; used to certify union-mode mirrors.)

These are implemented as eval assertions in `lib/flake/tests/` (cheap, no
realisation) plus an optional `pkgs.runCommand` build check for CI.

### 8.3 Cache sharing

Because GATE-M holds, the mirror and the monorepo produce the same derivation
hash; a binary cache/substituter serving either satisfies both, and Nix dedups
locally. No special "share the base" protocol is required in component mode. In
union mode, the shared base is passed explicitly and the resulting package drv
is again identical.

---

## 9. Dev-dependencies, checks, native inputs, platform gating

- **Dev-deps/tests.** `componentBase` uses `buildDepsOnly` with
  `doCheck = true`, so dev/test targets are primed once per component.
  `checks.fmt/lint/test` reuse `memberLayer` exactly as L (`:2480-2510`).
  `nativeCheckInputs` stay on the member/check layer.
- **Native build inputs.** The component base must receive the **profile** of
  build inputs needed to _compile_ dependencies, or two members with different
  build inputs would compute the same base with the wrong inputs (research §4.6,
  the latent 24-member bug). Implement `profileFor(component)`: union of
  `buildAttrs.nativeBuildInputs`/`buildInputs` of all component members; include
  it in `componentBase`. `nativeCheckInputs` are not part of the base.
- **Platform gating.** `availableAttrs` already drops packages unavailable on
  the host and `meta.platforms` gates `checks` to Linux. The component base uses
  only the **host-available** component dirs; if a component spans platforms,
  the base is built per host over the host-available subset (documented). A
  cross-platform in-repo path dep is flagged by the mirror generator as a G10
  hazard.
- **Mirror checks.** The mirror's `nix flake check` runs the same `checks`
  because it uses the same `default.nix`; `nativeCheckInputs` are carried by the
  vendored `default.nix`.

---

## 10. Mirror workflow, generator, and drift gate

### 10.1 Mirror unit = path-connected component

- Today: `{abird-host-agent, abird-host-manager}` is one unit; `hello-rust`,
  `nats-http-bridge`, `nats-wrecking-ball` are singletons. Non-workspace
  packages (`hello-rust-isolated`, `hello-go`, …) are already standalone and are
  out of scope.
- The unit is the smallest set that is buildable alone because of the
  `manager -> agent` path dependency; a "mirror the manager alone" mode is
  impossible without vendoring agent or rewriting the path dep.

### 10.2 Generator

Follow the `external-source-units.md` convention: convention is discovery, no
central catalog.

```text
mirrors/<unit>/
  mirror.nix      # { component = "pkgs/tools/abird-host-agent"; packages = [...]; repo = "..."; }
  update.sh       # executable: regenerate + optionally publish
```

`scripts/rust-mirror.sh`:

1. Reads `rust-components.nix` (component closure) and root
   `Cargo.toml`/`Cargo.lock`.
2. Copies byte-for-byte: root `Cargo.toml`, `Cargo.lock`, `treefmt.toml`, each
   component dir, vendored `lib/flake` (Tier 1) or the pinned input reference
   (Tier 2).
3. Emits `pkgs/manifest.nix` (component-filtered manifest; `args` wiring
   preserved).
4. Emits `flake.nix` from a template that calls `mkComponentFlakeOutputs`.
5. `--check` mode: generate into `$TMPDIR` and `diff -r` against the mirror
   checkout; nonzero on any drift.
6. `--publish`: push to the mirror repo (network step, separate command).

Everything is deterministic: sorted dirs, no timestamps, byte copies.

### 10.3 Drift gate

`checks.mirror-fresh` (offline) regenerates each mirror and diffs; any
hand-edit, stale lock, or stale `lib/flake` copy fails. `checks.mirror-parity`
runs GATE-M/GATE-B against the mirror via `path:` input or `--override-input`.
Together they make "minimal churn" enforceable rather than aspirational.

---

## 11. `lib/flake` extraction plan

**Tier 1 (default, smallest change):** the mirror vendors `lib/flake` bytes at
the same relative path. Because the layout is preserved, `pkg-helper.nix`'s
`../..` resolves to the mirror root and the four escapes are harmless. Drift is
caught by `mirror-fresh`. No parameterisation is required for dual mode.

**Tier 2 (optional isolated library):** make `lib/flake` a real flake input.

1. The function conversion in §4.1 removes the escapes: `repoRoot`,
   `defaultSrc`, `treefmtConfig` become arguments.
2. `stack/package.nix` and `packages.nix` instantiate the helper with
   `{ repoRoot; defaultSrc; }` provided by the flake (`self` / `./.`).
3. Rust-only mirrors bypass `stack/package.nix`'s eager `service-module.nix`
   import by calling `pkg-helper` directly (agent/manager do not use `srv`);
   packages that do use `srv` keep `stack/package.nix` (and thus
   `nixosModules`).
4. Mirror flake:
   ```nix
   inputs.lib = { url = "github:OWNER/lib-flake"; inputs.nixpkgs.follows = "nixpkgs"; inputs.crane.follows = "crane"; };
   ```
   and passes `defaultSrc = ./.` when instantiating the helper.
5. Version skew: a pinned input can drift from the monorepo. Mitigation:
   `follows` for nixpkgs/crane, `mirror-fresh` asserts the helper bytes match
   the monorepo's for Tier 1, and Tier 2 accepts semver-style lib versions. Tier
   1 is the recommended steady state until `package-project-boundaries.md`'s
   "desired future shape" is actively pursued.

The `service-module.nix` eager-import cost is eval-only and does not affect
drv-identity; it is why Rust-only mirrors should not pull `stack/package.nix`.

---

## 12. Composition and semantics analysis

### 12.1 What stays local

| change                                    | effect                                                                                    |
| ----------------------------------------- | ----------------------------------------------------------------------------------------- |
| `.rs` content in `m`                      | `buildSrc(m)` + `memberLayer(m)` + dependents; component base byte-stable (dummy-sourced) |
| `.rs` add/remove                          | same, subject to the L caveat; verify by spike S7                                         |
| member `Cargo.toml` external edit         | its component base + that component's members                                             |
| member path-dep edit                      | component changes; base/member set change within the component                            |
| `Cargo.lock` / `[workspace.dependencies]` | global (correct: genuinely global)                                                        |

### 12.2 Standalone vs merged

| coupling                       | E1 handling                                                         |
| ------------------------------ | ------------------------------------------------------------------- |
| `[workspace.dependencies]`     | full root manifest copied; no flattening, no rewrite                |
| single `Cargo.lock`            | copied verbatim; mirrors are lock snapshots (regenerated on change) |
| `manager -> agent` path dep    | mirror unit is the component; path entries verbatim                 |
| `default-features = false`     | untouched; no union widening, so polarity survives exactly          |
| dev-deps + native check inputs | same `default.nix`, same inputs; profile in base                    |
| root `[patch]`/`[replace]`     | absent today; if added, included by the byte copy                   |

### 12.3 No union widening

E1 never rewrites a member's external declarations, so a mirror resolves exactly
what the member resolves. There is no freshness gate needed for correctness
because there is no projection to under-approximate; the parity gate proves
identity instead. W10 (`[workspace.dependencies]` normalization) remains a dedup
nicety, not a correctness dependency.

---

## 13. Diagnostics and degradation

- `lib.warn` (never throw) when: component manifest parse/glob fails (fallback
  to `local`); `baseStrategy = "union"` in a context with absent members
  (fallback to `component`); `base` supplied but its vendor/lock differs
  (recompiles, correct); `craneLib == null` (legacy
  `rustPlatform.buildRustPackage`); an `externalPackagesFor` entry fails
  (fallback to in-repo); a component spans platforms.
- `passthru.baseStrategy/depsBase/componentDirs/mirrorUnit` (4.2) plus a
  `flake.mirrorPlan` output listing units, component dirs, generated files, and
  the chosen base strategy for `nix eval`.
- Degradation is always toward L (`baseStrategy = "local"` + no external
  inputs), which is the rollback shape.

---

## 14. Staged migration

| stage    | change                                                                                             | risk                        |
| -------- | -------------------------------------------------------------------------------------------------- | --------------------------- |
| **E0**   | add `base`/`baseStrategy` args + passthru; behavior unchanged (`union`)                            | none                        |
| **E1**   | add `rust-components.nix` + `component` strategy behind the flag; add `rust-workspace-deps` output | low; pure reader            |
| **E2**   | function-convert `pkg-helper.nix`; thread `externalPackagesFor`; add mirror output contract        | mechanical, 12 import sites |
| **E3**   | generator + one mirror (`{agent,manager}`); GATE-M/GATE-B; flip that component to `component`      | medium; first real build    |
| **E4**   | migrate remaining workspace members; add `mirror-fresh` to CI                                      | low                         |
| **E5**   | optional `lib/flake` Tier 2 extraction                                                             | medium; version skew        |
| rollback | `baseStrategy = "union"`, drop external inputs                                                     | restores landed L exactly   |

No package `default.nix` changes are required at any stage.

---

## 15. Validation spikes (must pass before E3)

- **S1** `rust-components.nix` on the real repo yields exactly
  `{{agent,manager},{hello-rust},{nats-http-bridge},{nats-wrecking-ball}}`,
  deterministic across evals; malformed manifest degrades with a warning.
- **S2** `componentBase` drv is byte-identical when computed from the monorepo
  and from a generated mirror (same source bytes, lock, vendor).
- **S3 (GATE-M component)**
  `mirror.mkPackage { pkgs; base = null }.drvPath ==
  member.drvPath`.
- **S4 (GATE-M union-shared)**
  `mirror.mkPackage { pkgs; base =
  member.sharedDepsBase }.drvPath == member.drvPath`
  while the monorepo runs union mode.
- **S5** swap `abird-host-agent` via `externalPackagesFor`; build/test the
  in-repo manager; its `internalDeps` picks up the external layer.
- **S6** `mirror-fresh` fails on a deliberate one-byte edit.
- **S7** `.rs` add/remove leaves `componentBase` byte-stable; content edit
  rebuilds only member+dependents.
- **S8** `--option allow-import-from-derivation false` evaluates monorepo and
  mirror.
- **S9** `nix flake check` on the mirror (incl. `nativeCheckInputs` such as
  `rsync`/`jq`).
- **S10** flake mechanics (already researched): `path:`, `?dir=`,
  `flake = false`, `follows`, `--override-input` all work; relative `path:` and
  untracked inputs are forbidden.

---

## 16. Complexity budget

| piece                                                                            | size                                  |
| -------------------------------------------------------------------------------- | ------------------------------------- |
| `rust-components.nix` (pure)                                                     | ~100 lines                            |
| `pkg-helper.nix` delta (base seam, component base, profiles, passthru, warnings) | ~130–180 lines                        |
| `pkg-helper.nix` function conversion                                             | ~15 lines + 12 one-token caller edits |
| `packages.nix` / `root.nix` / `default.nix` seam                                 | ~40 lines                             |
| `component-outputs.nix` + generated `flake.nix` template                         | ~80 lines                             |
| `scripts/rust-mirror.sh`                                                         | ~200 lines                            |
| eval tests + gates                                                               | ~120 lines                            |
| `lib/flake` Tier 2 (optional)                                                    | ~60 lines                             |

~700 lines, no new derivation kind (reuses `buildDepsOnly`/`cargoBuild`/
`buildPackage`).

---

## 17. Honest limits

1. **Component mode is a real compile cost.** Measured per-package/Plan-B bases
   are ≈753 vs union 367 at 5 members (≈2.05×); component-closure bases are no
   worse and usually slightly better. Union stays available; the `base` seam
   lets a monorepo inject its union base to reclaim speed without changing
   semantics. At 24 members this is the main scaling lever, and it is a knob,
   not a hidden property.
2. **`mirror drv == member drv` requires layout-preserving mirrors.** A "clean
   root" mirror (crate at repo root) cannot be drv-identical; it gets only
   GATE-S. Layout preservation is the price of exact cache sharing and is the
   default.
3. **The single `Cargo.lock` couples mirror freshness to the monorepo.** Mirrors
   are lock snapshots; any lock change requires regeneration. This is exactly
   why `mirror-fresh` is mandatory, and it is the same coupling L already has.
4. **`[workspace.dependencies]` inheritance forces the whole root manifest into
   every mirror.** The mirror's root `Cargo.toml` is not a curated standalone
   manifest; it is a byte copy with an absent-members list that `prePatch`
   rewrites. `cargo` and crane both tolerate this (verified mechanics); a future
   `[workspace.package]` split could make it cleaner.
5. **Component membership is manifest-derived.** A typo in a path dep can merge
   or split the wrong component. The reader warns and the mirror gate catches
   drift, but the graph is only as good as the manifests.
6. **Non-workspace packages gain nothing.** `hello-rust-isolated` etc. already
   take the legacy path; they are not part of the component graph.
7. **Union mode is not standalone-reproducible.** That is inherent (research
   §4.3–4.5); E1 is honest that union is a monorepo cache optimization, not a
   mirror format.
8. **No new exactly-once claim.** E1 claims per-component dependency reuse and
   `.rs` locality; a dependent can still recompile an in-component crate when
   feature requests differ. GATE-S bounds and documents it.

---

## 18. Where L-KEEP beats the alternatives

- **vs. E2 (definition/adoption redesign):** E2 changes how packages are defined
  and adopted before mirroring is proven. L-KEEP changes neither the package
  surface nor the manifest: `default.nix` is untouched, resolution semantics are
  unchanged, and adoption is per-component with a one-flag rollback. That is
  strictly lower migration risk for the same G10/G11 outcome.
- **vs. E3 (mirror-first redesign):** E3 builds the mirror repos first, which
  requires a divergent standalone layout/manifest and creates hand-sync churn
  before the monorepo seam exists. L-KEEP inverts it: the monorepo and mirror
  share one layout and one emitter, so the mirror is generated, diffable, and
  **bit-identical** to the member (`drvPath` equality), giving automatic cache
  sharing instead of "ideally". E3's clean root layout cannot reach drv identity
  without the same layout-preservation trick, at which point it converges on
  L-KEEP with more machinery.

The one deliberate trade — layout-preserving mirrors are less pretty than
clean-root mirrors — is what buys E1 its exact `mirror drv == member drv` and
G11 cache sharing, and it costs zero per-package maintenance.

---

## 19. References

- `tmp/design-f2/research.md` — council research (facts, measurements,
  mechanics).
- `.agents/docs/notes/tooling/rust-build-graph-dual-mode-goals-2026-09.md` —
  G10/G11.
- `.agents/docs/plans/design-f-build-graph-2026-09.md` — REWEAVE (rejected
  spine).
- `lib/flake/pkg-helper.nix` — `defaultCargoPackageArgs:33`,
  `craneWorkspaceCargoArgs:37`, `mkWorkspaceSourcePath:67`,
  `mkCargoWorkspaceSource:102`, `rustWorkspaceMembers:142`,
  `mkRustWorkspaceSource:167`, `mkSharedRustDepsBase:179`,
  `mkCargoArtifactsJoin:198`, `cargoWorkspacePrePatch:235`,
  `mkTrunkProject:1510`, `mkRustDerivation:2103`, `memberLayer:2400`.
- `lib/flake/{default,root,packages,stack/package}.nix` — composition seams.
- `pkgs/tools/abird-host-agent/default.nix`,
  `pkgs/tools/abird-host-manager/default.nix`, `pkgs/manifest.nix` — the
  component and its wiring.
- `.agents/docs/design-patterns/package-project-boundaries.md` — extraction
  target.
- `.agents/docs/design-patterns/shared-test-areas.md`,
  `.agents/docs/design-patterns/external-source-units.md` — generator/drift
  discipline.
- Crane `rev 73b9805`: `lib/buildDepsOnly.nix`, `lib/mkDummySrc.nix`,
  `lib/setupHooks/inheritCargoArtifactsHook.sh`, `lib/vendorCargoDeps.nix`.
