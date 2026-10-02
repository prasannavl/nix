# ECHO — Mirror-first build graph (standalone component flake is the unit of truth)

Status: **design proposal, candidate E3, council 2**. Read with
`tmp/design-f2/research.md` (mechanics), the dual-mode goals note, and
`.agents/docs/plans/design-f-build-graph-2026-09.md` (REWEAVE prior art).

---

## 0. Thesis (one paragraph)

Make the **standalone component flake the primary artifact**, not a mirrored
afterthought. A component (the path-connected unit of Cargo path-dependency
closure) owns a generated, thin `flake.nix` exposing a small **stable output
contract**; the monorepo consumes that contract and _composes_ the component
instead of owning the build graph. Composition is a pure function call
(`lib.mkPackage { base; }`), not a fork, and the base is an injected
`cargoArtifacts` seam. Because the mirror preserves the monorepo-relative file
layout and copies the exact `Cargo.toml`/`Cargo.lock`, and because both sides
feed `pkgHelper.mkRustDerivation` identical source/buildSrc/base arguments, the
composed derivation is **bit-identical** to the in-repo derivation, and (under
the exact base policy) the standalone derivation is bit-identical to the
composed one. The single shared artifact between component and monorepo is the
extracted `lib/flake` (`flake-lib`), consumed as a `follows`-aligned input so
there is no version skew in a composition. We drop REWEAVE's union manifest
rewrite entirely: L's per-member `-p m` resolution is already
composition-independent, so a shared/union base is a _cache hint_, never a
semantic input.

The design's core lever is a layout decision the REWEAVE research did not take:
**do not flatten the mirror**. Keep `projectDir = "pkgs/tools/abird-host-agent"`
in the mirror by preserving the monorepo subtree inside the mirror repo. That
single choice makes sources content-addressed-identical across repos and turns
drv-equality from a hope into an equation.

---

## 1. Goals, invariants, non-goals

### 1.1 Restated goals

- **No IFD.** Everything that inspects manifests/locks at evaluation time reads
  evaluator-visible paths only.
- **Correctness first.** L's `-p m` semantics are the contract. No union
  rewrite.
- **Scalable to 24 members.** Base strategy and eval strategy must both have a
  documented cost curve, not a cliff.
- **G10 dual mode.** Every component is standalone-buildable in its own repo;
  `lib/flake` is optionally extractable.
- **G11 seamless replacement.** The monorepo can consume the mirror's flake and
  use it in place of the in-repo component with the same semantics and
  artifact/cache sharing.

### 1.2 Design invariants (testable)

1. **I1 — same call.** In-repo and composed-mirror packages are produced by the
   _same_ `pkgHelper.mkRustDerivation` call with the same arguments. No parallel
   builder, no conditional fork.
2. **I2 — source identity.** The component source tree handed to crane is
   NAR-identical between monorepo and mirror (same relative paths, same bytes),
   so `builtins.path` yields the same store path.
3. **I3 — base is an argument.** The dependency base is supplied through the
   contract (`base`/`cargoArtifactsBase`), never silently derived from a
   monorepo-global object inside the member builder.
4. **I4 — one lib.** `pkgHelper` comes from exactly one `flake-lib` revision
   within a composition (`follows`), and the component's default definition is
   byte-identical to the mirror's generated copy.
5. **I5 — no IFD.** No `import`/`readFile` of a derivation output at eval.
6. **I6 — layout stable.** The mirror preserves the monorepo-relative paths of
   the component's tracked files.

### 1.3 Non-goals

- Proving bit-identical _binaries_ across different bases (we prove semantic
  equality via `cargo tree -e features`, and drv equality only under the exact
  base policy).
- Solving the W10 transitive feature residual. ECHO scopes it to the component
  and detects it with an optional freshness gate; it does not remove it.
- A general third-party monorepo tool. This is repo-specific tooling.

---

## 2. Architecture

```text
                      ┌───────────────────────────────────────────────┐
                      │  flake-lib (extracted lib/flake, own flake)   │
                      │  pkg-helper.nix (parameterized escapes)       │
                      │  mkComponentBase  mkComponentSource           │
                      │  mkComponentFlake  mkStdFlakeOutputs          │
                      └───────────────┬───────────────────────────────┘
                                      │ follows / one rev
        ┌─────────────────────────────┼──────────────────────────────┐
        │                             │                              │
┌───────▼────────┐          ┌─────────▼──────────┐        ┌──────────▼─────────┐
│ component repo │          │ component repo      │        │ monorepo flake     │
│  (standalone)  │          │  (standalone)       │        │  inputs:           │
│                │          │                     │        │   nixpkgs/crane    │
│ flake.nix      │          │ flake.nix           │        │   flake-lib        │
│ component.nix  │          │ component.nix       │        │   mirrors (flake=  │
│ pkgs/.../      │          │ pkgs/.../           │        │     false, optional)│
│ Cargo.toml/lock│          │ Cargo.toml/lock     │        │  composes:         │
│ packages.*     │          │ packages.*          │        │   in-repo component│
│ lib.mkPackage  │          │ lib.mkPackage       │        │   or mirror flake  │
└────────────────┘          └─────────────────────┘        │   with union base  │
                                                          └────────────────────┘
```

Three layers, one contract:

- **`flake-lib`** — the pure builder + base + contract helpers.
  Repository-blind.
- **component flake** — the source of truth for a component's definition,
  standalone outputs, and the composition seam. Generated thin; never
  hand-diverged from the definition.
- **monorepo** — a composer: it builds bases, reads component definitions, and
  calls `lib.mkPackage`. It no longer owns per-package build logic.

The monorepo keeps a central registry (`pkgs/components.nix` +
`pkgs/manifest.nix`) purely for _discovery and composition_, not for build
semantics.

---

## 3. The flake output contract

Every component flake (in-repo and mirror) exposes the same contract, per
system. This is the API a consumer learns once.

```nix
# outputs = { nixpkgs, flake-utils, crane, flake-lib, ... }@inputs:
{
  # ---- standalone outputs (G10) ----------------------------------------
  packages.<system>."<pname>"        = <derivation>;   # one per component member
  packages.<system>.default          = <default member derivation>;
  checks.<system>."<pname>" = {
    build = <derivation>;
    fmt   = <cargoFmt>;
    lint  = <cargoClippy>;
    test  = <cargoTest>;
  };
  apps.<system>."<pname>"            = <app>;           # if meta.mainProgram
  devShells.<system>.default         = <mkShell>;
  formatter.<system>                 = <treefmt/alejandra driver>;
  nixosModules                       = { ... };        # optional, service-stack only

  # ---- composition API (G11) -------------------------------------------
  # Pure function. `base` is the injected cargoArtifacts seam. Calling this
  # with base = null reproduces packages.<system> exactly.
  lib.mkPackage.<system> = {
    pkgs ? <default pkgs for system>,
    base ? null,                 # a cargoArtifacts-capable derivation
    pkgHelper ? <the flake-lib helper>,
    internalPackages ? {},       # sibling component packages (path deps)
  } -> { "<pname>" = <derivation>; ... };

  # ---- metadata, no derivation realization -----------------------------
  definition.<system> = {
    component = { id; members = [ <monorepo-relative dirs> ]; };
    packages."<pname>" = {
      pname; version; projectDir; deps; internal; platforms;
      cargoArgs; nativeBuildInputs; nativeCheckInputs; mainProgram;
      extraPassthru;
    };
  };
}
```

Additionally, each produced derivation carries the legacy-compatible passthru
shape, extended with the contract metadata:

```nix
passthru = {
  # existing (Design L) shape — keep for consumers
  projectDir; sourcePath; memberLayer; sharedDepsBase;
  checks; fmt; lint-fix; pkgOps;
  # ECHO additions
  definition;        # the definition attrset above
  build;             # = the derivation itself
  component;         # component id
  base;              # the injected base actually used (for diagnostics)
};
```

**Why both `lib.mkPackage` and `packages.default`?** `packages.default` is the
standalone build (its own component base). `lib.mkPackage` is the composition
seam: the monorepo injects its base and sibling packages. If `base == null`,
`lib.mkPackage` and `packages.default` are the same derivation by construction
(they literally call the same function).

### 3.1 The definition file (author-facing, unchanged feel)

The author keeps editing a `default.nix`-shaped definition. It becomes a
function that receives the injected context:

```nix
# pkgs/tools/abird-host-agent/default.nix
{ pkgs, pkgHelper, base ? null, internalPackages ? {} }:
pkgHelper.mkRustDerivation {
  inherit pkgs base;
  pname = "abird-host-agent";
  version = "0.1.0";
  projectDir = "pkgs/tools/abird-host-agent";
  nativeCheckInputs = [ pkgs.rsync ];
  buildAttrs.doCheck = false;
  enableDevShell = true;
  meta = {
    description = "...";
    mainProgram = "abird-host-agent";
    platforms = pkgs.lib.platforms.linux;
  };
}
```

Differences from today are exactly: `base` is now an explicit argument (default
`null` preserves the old behavior), and `pkgHelper`/`pkgs` are injected (the
relative `import ../../../lib/flake/pkg-helper.nix` default remains as a
repo-only fallback and is never forced when the flake supplies it). The
`projectDir` and `deps` strings are _unchanged_ because the mirror preserves the
layout.

For the multi-crate component, the definition file exposes both packages and
their internal edge:

```nix
# pkgs/tools/abird-host-component/component.nix  (generated, thin)
{ component = { id = "abird-host"; members = [
    "pkgs/tools/abird-host-agent"
    "pkgs/tools/abird-host-manager"
  ]; };
  packages = {
    abird-host-agent  = import ../abird-host-agent/default.nix;
    abird-host-manager = import ../abird-host-manager/default.nix;
  };
}
```

`abird-host-manager/default.nix` already accepts `abirdHostAgent`; we map the
contract's `internalPackages` onto it:

```nix
{ pkgs, pkgHelper, base ? null, internalPackages ? {} }:
let
  abirdHostAgent = internalPackages.abird-host-agent or null;
in
pkgHelper.mkRustDerivation {
  inherit pkgs base;
  pname = "abird-host-manager";
  projectDir = "pkgs/tools/abird-host-manager";
  deps = [ "pkgs/tools/abird-host-agent" ];
  internalDeps = pkgs.lib.optional (abirdHostAgent != null) abirdHostAgent;
  # ... unchanged ...
}
```

The component flake resolves `internalPackages` with lazy recursion (`lib.fix`),
so declaration order does not matter and cycles are a Nix error, not a silent
misbuild.

---

## 4. Component model and the mirror unit

### 4.1 The unit is the path-connected component

`manager -> agent` is a Cargo path dependency. A standalone `manager` cannot be
built without `agent`, so the minimal standalone unit is the connected component
in the path-dependency graph (research §6.1). ECHO adopts this honestly:

- single-crate components (most packages): mirror repo == package repo;
- multi-crate components (`{abird-host-agent, abird-host-manager}`): one mirror
  repo exposing both `packages.abird-host-agent` and
  `packages.abird-host-manager`.

`pkgs/components.nix` (new, generated once, then maintained) is the graph:

```nix
{
  abird-host = {
    members = [ "pkgs/tools/abird-host-agent" "pkgs/tools/abird-host-manager" ];
    definition = ./tools/abird-host-component/component.nix;
  };
  nats-http-bridge = { members = [ "pkgs/support/nats-http-bridge" ]; definition = ...; };
  # ... 24 entries
}
```

`pkgs/manifest.nix` gains a `component = "<id>"` field per package or is derived
from the graph. The manifest stays the discovery registry; it no longer drives
build semantics.

### 4.2 Mirror = preserved subtree + verbatim manifests + generated flake

The mirror generator materializes:

```text
<mirror>/
  flake.nix                 # generated thin template
  flake.lock                # generated, pins nixpkgs/crane/flake-lib
  component.nix             # generated, same content as in-repo
  pkgs/tools/abird-host-agent/{Cargo.toml,src/...,default.nix}
  pkgs/tools/abird-host-manager/{Cargo.toml,src/...,default.nix}
  Cargo.toml                # exact copy of monorepo root manifest
  Cargo.lock                # exact copy of monorepo lock
  .cargo/                   # exact copy (if present)
  .gitignore                # exact copy (filter determinism)
```

Key rules:

- **Preserve relative paths.** This is I6 and the reason `projectDir` is not a
  per-package divergence. It directly contradicts research §2.5's assumption
  that the mirror must flatten to `"."`; flattening would destroy drv equality.
- **Verbatim root `Cargo.toml` + `Cargo.lock`.** The root manifest lists all
  monorepo members, but only the component's member dirs exist in the mirror.
  That is safe because every build applies the existing members-rewrite
  `prePatch` before cargo runs (research §3.4, locktest2: `--locked --offline`
  preserves the lock when only the member list is rewritten). The lock is kept
  whole so `vendorCargoDeps` hashes identical bytes across repos.
- **No extra files.** The component source is `builtins.path`-filtered to member
  dirs + root manifests + `.cargo`; any stray file the mirror adds would change
  the filter result only if it falls inside a selected path. The generator must
  copy exactly the tracked files of the component.

Why this works: `builtins.path` is content-addressed. A tree with the same
relative paths and bytes has the same store path regardless of which repo it
came from. The mirror is a byte-identical _subtree_, so the filtered component
source is the same store path, so `mkDummySrc`, the component base, the member
source, and the package are the same derivations.

### 4.3 The generated flake

```nix
# pkgs/tools/abird-host-component/flake.nix  (generated)
{
  description = "ECHO component: abird-host";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    flake-utils.url = "github:numtide/flake-utils";
    crane.url = "github:ipetkov/crane";
    flake-lib.url = "github:<org>/abird-flake-lib";
    flake-lib.inputs.nixpkgs.follows = "nixpkgs";
    flake-lib.inputs.crane.follows = "crane";
  };
  outputs = inputs:
    (inputs.flake-lib.lib.mkComponentFlake {
      inherit inputs;
      componentNix = ./component.nix;
      src = ./.;
    });
}
```

This differs from the 13 existing wrappers (research §5.1): it imports the
extracted lib (not a relative path into the monorepo) and the lib supplies the
crane overlay, so `pkgs.craneLib` is real and we get the L member-layer path,
not the `rustPlatform.buildRustPackage` fallback. `hello-rust-isolated` is
superseded (it becomes a normal single-crate component with `src = ./.;`).

---

## 5. Monorepo composition

### 5.1 The swap seam

We add the minimal seam research §1.4 recommended, but extend it to return a
whole component interface rather than a single derivation:

```nix
# flake.nix (root)
inputs = {
  nixpkgs.url = ...; crane.url = ...;
  flake-lib = { url = "path:./lib/flake"; inputs.nixpkgs.follows = "nixpkgs"; };
  # optional: a raw source tree containing all mirror repos, no flake eval
  mirrors = { url = "path:./dist/mirrors"; flake = false; };
  # optional: a specific mirror consumed as a real flake input
  mirror-abird-host = { url = "github:<org>/abird-host"; flake = true; };
};
outputs = inputs: (import ./lib/flake/root.nix {
  inherit inputs;
  externalPackagesFor = _system: {
    # component id -> interface exposing lib.mkPackage
    abird-host = inputs.mirror-abird-host;
  };
}).outputs;
```

Threaded `flake.nix -> root.nix -> default.nix -> withPkgs -> packages.nix` as a
defaulted argument `externalPackagesFor ? _system: {}`. `withPkgs` gains an
`inputs` (or an `interfaces`) parameter so `packages.nix` can see flake inputs
(research: `manifest.nix` is pure data and cannot).

Three consumption modes, one interface:

| mode                          | how the interface is obtained                                  | eval cost                                                  |
| ----------------------------- | -------------------------------------------------------------- | ---------------------------------------------------------- |
| in-repo (default)             | `import pkgs/<...>/component.nix { inherit inputs pkgs ...; }` | none beyond today                                          |
| mirror tree (`flake=false`)   | `(import (mirrors + "/<id>/flake.nix")).outputs inputs`        | one source fetch, no lock/eval of the mirror's own nixpkgs |
| external flake (`flake=true`) | `inputs.<mirror>.lib.mkPackage` (already evaluated)            | one flake input eval                                       |

The composition normalizes all three to
`{ lib.mkPackage.${system}; definition; }` and never branches again.

### 5.2 One-line swaps

- Declarative, whole mirror tree: point `mirrors.url` at a checkout and set
  `externalPackagesFor` to the components you want swapped.
- Declarative, one component: add `inputs.mirror-<id>` + one mapping line.
- Temporary, no file edit:
  `nix build .#abird-host-manager --override-input mirrors path:/tmp/mirror-checkout --no-write-lock-file`
  (works for both `flake=false` and `flake=true` inputs; verified primitives in
  research §1.1).

The `--override-input` path requires the input to be declared in `flake.nix`
(Nix cannot override an undeclared input), which is why we keep a single
`mirrors` input even in the default configuration when mirror swapping is
anticipated.

### 5.3 Composition code (sketch)

```nix
# lib/flake/components.nix  (new; replaces the per-package map in packages.nix)
{
  pkgs, inputs, externalPackagesFor, registry, baseFor,
}: let
  system = pkgs.stdenv.hostPlatform.system;
  lib = inputs.flake-lib.lib;
  interfaces = builtins.mapAttrs (id: comp:
    let
      external = (externalPackagesFor system).${id} or null;
      inRepo =
        (import comp.definition {
          inherit inputs;
          component = comp;
          src = inputs.self;
          pkgHelper = lib.pkgHelper;
        }).outputs;
    in
      if external != null then external
      else inRepo
  ) registry;
  # each component may host several packages; resolve internal edges with fix
  composed = builtins.mapAttrs (id: iface:
    iface.lib.mkPackage.${system} {
      inherit pkgs;
      base = baseFor id;        # union base (default) or component base
      internalPackages = {};    # filled from the same component's fix
    }
  ) interfaces;
in
  # flatten { component = { pname = drv; }; } -> { pname = drv; }
  builtins.foldl' (acc: id: acc // composed.${id}) {} (builtins.attrNames registry);
```

`baseFor id` is the policy hook (§6). The in-repo `iface` is produced by the
_same_ `mkComponentFlake`/`lib.mkPackage` that the mirror uses, so I1 holds.

---

## 6. Base sharing and the `cargoArtifacts` seam

### 6.1 The seam

`pkgHelper.mkRustDerivation` gains one optional argument:

```nix
cargoArtifactsBase ? null,
```

and `workspaceMode`/`prefixNode` become:

```nix
workspaceMode = cargoArtifactsBase != null
                || (useWorkspaceDeps && craneLib != null && projectDir != null
                    && builtins.isPath src && isWorkspaceMember src projectDir);

prefixNode =
  if cargoArtifactsBase != null then cargoArtifactsBase
  else if !workspaceMode then packageCargoArtifacts
  else sharedDepsBase;         # legacy fallback, unchanged
```

This is the whole G11 sharing mechanism. The component flake always passes
`base` (its own standalone base or the composed one); the monorepo passes the
base selected by policy. `sharedDepsBase` remains for the legacy path and for
`basePolicy = "union"` when we want the monorepo to compute it once.

### 6.2 Two coherent base policies

| policy            | base passed                                                                         | cost                                               | guarantee                                                                         |
| ----------------- | ----------------------------------------------------------------------------------- | -------------------------------------------------- | --------------------------------------------------------------------------------- |
| `union` (default) | repo-wide `--workspace` base over all members (L's existing `mkSharedRustDepsBase`) | measured 367 external compiles / current 5 members | composed(mirror) drv == in-repo drv; standalone uses its own base ⇒ semantic only |
| `component`       | `mkComponentBase` over the component's member dirs only                             | measured 753 / 5 members (~2.05×)                  | standalone drv == composed drv == in-repo(component base) drv                     |

`basePolicy = component` is the **exact G11 mode**: it is what makes the "drv
equality across standalone/composed" proof unconditional. `union` is the
performance default: the monorepo injects its fast shared base and the composed
mirror is byte-identical to the in-repo package, so _replacement_ is
transparent; only a _purely standalone_ build sees a different base.

We deliberately do **not** claim one base satisfies both maximal dedup and
mirror-identical output; that is the honest tension research §4.5 identified.
ECHO exposes it as a one-word knob instead of hiding it.

### 6.3 `mkComponentBase` (new in `pkg-helper.nix`)

```nix
mkComponentBase = pkgs: {
  src, members, pname, cargoLockContents, cargoVendorDir,
  nativeBuildInputs ? [], buildInputs ? [],
}: let craneLib = pkgs.craneLib; in
craneLib.buildDepsOnly {
  dummySrc = craneLib.mkDummySrc {
    src = mkWorkspaceSourcePath pkgs {
      inherit src;
      selectedDirs = map normalizeMemberPath members;
    };
  };
  pname = "abird-rust-${pname}";
  version = "0.1.0";
  cargoExtraArgs = "--locked --offline --workspace";
  prePatch = cargoWorkspaceMembersPrePatch {
    members = builtins.sort builtins.lessThan (map normalizeMemberPath members);
  };
  inherit cargoLockContents cargoVendorDir nativeBuildInputs buildInputs;
};
```

Two required supporting changes:

1. Factor the awk in `cargoWorkspacePrePatch` into
   `cargoWorkspaceMembersPrePatch { members }` (REWEAVE §5.2 already specifies
   this; `cargoWorkspacePrePatch` becomes a caller). This lets the base rewrite
   the root member list without a `projectDir`.
2. `mkWorkspaceSourcePath` keeps the root `Cargo.toml` verbatim and the lock
   verbatim (already true).

`mkSharedRustDepsBase` is retained unchanged so `basePolicy = union` is
bit-compatible with landed L (modulo an optional members-sort if we choose to
canonicalize; default: leave it untouched to avoid churn).

### 6.4 Exact cargo invocations

Component base (standalone and, under `component` policy, composed):

```text
# buildDepsOnly, doCheck = true, CRANE_BUILD_DEPS_ONLY=1
cargoWithProfile check --locked --offline --workspace --all-targets
cargoWithProfile build --locked --offline --workspace
cargoWithProfile test  --locked --offline --workspace --no-run
# prePatch: rewrite root [workspace].members := component members (sorted)
```

Member layer (`cargoBuild`, per package):

```text
# src = mkCargoWorkspaceSource { projectDir; deps = [projectDir] ++ internalDirs; }
# prePatch = cargoWorkspacePrePatch { projectDir; deps; }
# cargoArtifacts = base | internal dependency's memberLayer
cargoWithProfile build --offline -p <pname>
# doInstallCargoArtifacts = true
```

Deployed package (`buildPackage`):

```text
# cargoArtifacts = memberLayer; same src/prePatch as the member layer
cargoWithProfile build --offline -p <pname>     (install via memberLayer artifacts)
```

Checks:

```text
cargo fmt -p <pname> --check
cargo clippy --offline -p <pname> -- -D warnings
cargo test  --offline -p <pname>
```

Internal fan-in stays L's special case: zero internal deps → base; one → that
dep's `passthru.memberLayer`; two+ → `mkCargoArtifactsJoin` (unchanged).

---

## 7. Extracting `lib/flake` (`flake-lib`)

### 7.1 Blockers and fixes

Research §2 lists four relative escapes in `pkg-helper.nix` plus the service
stack coupling. ECHO's extraction is mechanical:

| escape                                                   | line                | fix                                                                                                                                       |
| -------------------------------------------------------- | ------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `repoRoot = builtins.toString ../..`                     | `pkg-helper.nix:11` | argument `repoRoot ? null`; `deriveProjectPath` only used when non-null                                                                   |
| `--config-file ${../../treefmt.toml}`                    | `:474`              | argument `treefmtConfig ? null`; omit the flag when null                                                                                  |
| `src ? ../..` in `mkTrunkProject`                        | `:1529`             | require explicit `src`                                                                                                                    |
| `src ? ../..` in `mkRustDerivation`                      | `:2116`             | require explicit `src` (the component flake always passes it)                                                                             |
| `stack/package.nix` eagerly imports `service-module.nix` | `stack/package.nix` | split: `flake-lib` is Rust/package helpers; `flake-lib-service` (or the repo composition) owns `service-module.nix` + `stack/package.nix` |

`flake-lib` is a real flake with its own `flake.nix`:

```nix
{
  inputs = { nixpkgs.url = ...; flake-utils.url = ...; crane.url = ...; };
  outputs = { self, nixpkgs, flake-utils, crane }: {
    lib = {
      pkgHelper = import ./pkg-helper.nix;
      mkComponentFlake = import ./mkComponentFlake.nix { inherit nixpkgs; };
    };
    overlays.default = final: prev: { craneLib = crane.mkLib prev; };
    templates.component = { path = ./templates/component; };  # `nix flake init`
  };
}
```

### 7.2 Version skew policy

- Every component flake declares `flake-lib` and `follows` its
  `nixpkgs`/`crane`.
- In a composition the monorepo wins:
  `inputs.<component>.inputs.flake-lib.follows
  = "flake-lib"` (for
  `flake=true`), and for `flake=false`/in-repo the monorepo passes its own
  `pkgHelper` directly. One rev per composition ⇒ no skew.
- Standalone mirrors pin their own `flake-lib` rev. The mirror drift gate
  asserts the pinned rev's contract version matches the monorepo's
  `flake-lib.contract` (a small integer in the lib). Mismatch is a hard CI
  failure, not a silent build.
- Fallback if extraction proves too costly: a vendored-sync mode (research §2.4)
  where each component carries a byte-identical copy of the lib checked by the
  same drift gate. ECHO prefers the input because it removes byte-sync
  maintenance; the vendored mode is retained as a documented escape hatch.

### 7.3 Service stack

Rust-only components must not pull 1215 lines of `service-module.nix` (research
§2.2). `flake-lib` exposes no service code. `nixosModules` for a component are
produced by a separate optional input `flake-lib-service`, injected only by the
components that declare `nixosModule`. The monorepo's existing
`rootLib.nixosModules` wiring is unchanged; only the import location moves.

---

## 8. G10/G11 mechanics and proofs

### 8.1 Definitions

- `M` = monorepo root path (evaluator-visible).
- `R` = mirror root path; `μ` = the generator's file map from the component's
  tracked files in `M` to `R` (path-preserving).
- `S_c(X) = mkWorkspaceSourcePath { src = X; selectedDirs = memberDirs(c); }`
  for `X ∈ {M, R}`.
- `B_c(X) = mkComponentBase { src = X; members = memberDirs(c); ...; }`.
- `P_c(X, b) = mkRustDerivation { src = X; projectDir = ...; base = b; ...; }`
  (via the component contract).
- `U` = the monorepo union base.

### 8.2 Lemma 1 (source identity)

**Claim:** `S_c(M) = S_c(R)` as store paths.

_Proof:_ `S_c` is `builtins.path` with a filter selecting member dirs + root
`Cargo.toml`/`Cargo.lock`/`.cargo`; Nix content-addresses the filtered NAR. `μ`
preserves every selected relative path and byte (generator copies tracked files
only; root manifests and lock are verbatim; `.cargo`/`.gitignore` copied). The
filtered trees are therefore byte-identical, so their NAR hashes and store paths
coincide. ∎

_Assumption:_ the generator adds no file inside a selected path. The drift gate
enforces this (§10). `.gitignore` must be copied because `mkWorkspaceSourcePath`
uses `nix-gitignore.gitignoreFilterPure`.

### 8.3 Lemma 2 (base identity, component policy)

**Claim:** `B_c(M) = B_c(R)` as derivations.

_Proof:_ `buildDepsOnly`'s inputs are `dummySrc` (from `S_c`, Lemma 1), the
cleaned manifest stubs (eval-time reads of the same manifests), the lock bytes
and vendor dir (verbatim, so `vendorCargoDeps` is identical), the member-rewrite
`prePatch` script (a pure function of the sorted member list), `pname`,
`cargoExtraArgs`, and native inputs. All identical ⇒ same derivation. ∎

### 8.4 Lemma 3 (member identity)

**Claim:** for identical `src`, `base`, and builder args,
`P_c(M, base) = P_c(R, base)`.

_Proof:_ `mkRustDerivation` is a pure function of its arguments; the only
repo-dependent argument is `src`, and Lemma 1 gives identical filtered sources.
`buildSrc`, `prePatch`, `cargoArtifacts`, and `cargoExtraArgs` are therefore
identical. ∎

### 8.5 Theorem A (G11 composed == in-repo, union policy)

**Claim:** `compose(inRepo, U) = compose(mirror, U)`.

_Proof:_ both calls are `lib.mkPackage { base = U; }` on interfaces produced by
the same `mkComponentFlake`; by Lemmas 1 and 3 the resulting package derivations
are equal. This is the "seamless replacement" guarantee: the monorepo cannot
tell whether it built the in-repo or mirrored component. ∎

### 8.6 Theorem B (standalone == composed, component policy)

**Claim:** `standalone(mirror) = compose(mirror, B_c(R))` and
`compose(inRepo, B_c(M)) = standalone(mirror)`.

_Proof:_ `standalone` is `lib.mkPackage { base = B_c(R); }`; composed under
`component` policy injects `B_c(M)`. Lemma 2 gives `B_c(M) = B_c(R)`; Lemma 3
gives all three package derivations equal. ∎

### 8.7 Corollary (G10)

The mirror's `packages.default` evaluates and builds with `src = ./.` and no
monorepo root: it needs only its own `Cargo.toml`/`Cargo.lock`/member dirs plus
`flake-lib`. No `../..` escape remains after §7. ∎

### 8.8 Cross-policy semantic equality

Under `union`, `standalone` and `composed` share `projectDir`, manifests, lock,
`-p m` args, and source bytes, and differ only in the inherited
`cargoArtifacts`. Because Cargo feature unification is selection-based, `-p m`
selects the same root requirement table in both; the union base only adds extra
pre-compiled units. The installed binaries are therefore semantically identical.
Gate V-feat (§11) verifies this by diffing `cargo tree -e features -p m` and the
member-layer compile log. ∎

### 8.9 What the proofs need from L

Nothing new in the builder. Lemma 1 relies on content-addressing
(`builtins.path`), Lemma 3 on the builder being a pure function (already true),
and Theorem B on the injected base (the one new argument). REWEAVE's union
rewrite is not needed and is not used.

---

## 9. Semantics and composition analysis

### 9.1 Composition independence (why dropping REWEAVE is safe)

Research §3.1 established that landed L already builds members with
`cargo build --offline -p <m>` over a source filtered to `[projectDir] ++ deps`
with the root `members` rewritten. The deployed crate's feature/version
resolution therefore depends only on its component's manifests, not on peers.
REWEAVE is precisely what reintroduces peer dependence by rewriting member
manifests to a shard union (research §3.2). ECHO keeps L's resolution and treats
the union base as a cache hint, which is exactly why G11 replacement is
transparent.

### 9.2 The remaining coupling: lock + workspace.dependencies

The only genuinely monorepo-global inputs are `Cargo.lock` and
`[workspace.dependencies]`. ECHO handles them by _copying_ them verbatim into
every mirror (lock) and by rewriting only `[workspace].members` at build time
(workspace deps stay in the verbatim root manifest). Consequences:

- A mirror reproduces its component's resolution byte-for-byte (research §3.4).
- A peer adding a dependency (changing the root manifest/lock) changes the
  verbatim root manifest, so every component source changes → every component
  base changes. This is L's current global churn, now per-component. It is
  correct, not hidden.
- **Churn reduction (optional, later):** replace the verbatim root manifest in
  the component source with a canonical component manifest computed purely from
  the root manifest and the component's member manifests (subset of
  `[workspace.dependencies]` actually referenced + `[workspace.package]` +
  `[patch]`/`[replace]` verbatim). Both monorepo and mirror compute it with the
  same function from the same verbatim input, so drv equality is preserved while
  churn localizes to components that use a changed dep. This is a ~60-line pure
  function, not a REWEAVE planner: it never touches features or versions.

### 9.3 Cross-component semantics

Shards/components are closed under path deps by construction (§4.1), so no
cross-component path edge exists and a component's `-p m` selection is a subset
of its own graph. External transitive features that differ because two members
of the same component request different features on a shared external are the
W10 residual. ECHO does not force them to agree; it scopes the possible extra
recompiles to the component. The optional freshness gate (§11, V-fresh) is the
detector, inherited from REWEAVE but demoted from "correctness backstop" to
"cache-efficiency diagnostic", because under L semantics a mismatch cannot
change the member binary.

### 9.4 Dev-dependency semantics

The component base runs with `doCheck = true`, priming dev/test units for the
component members via `cargo test --no-run` (crane `buildDepsOnly`). Member
checks reuse the base; resolver 3 keeps dev features out of the normal domain.
Because the base is component-scoped, a component member's dev-deps are primed
once per component, not repo-wide. This is correct and mirror-identical.

---

## 10. Dev-deps, checks, and the mirror/publish workflow

### 10.1 Checks

Each component flake exposes `checks.<system>.<pname>.{build,fmt,lint,test}`.
The monorepo can consume either the in-repo checks or the mirror's; under
`component` policy they are the same derivations. `nix flake check` on a mirror
is a complete standalone validation. The monorepo keeps its existing
`checks`/`pkgOps`/`lint` wiring; the package-level checks now originate in the
contract.

### 10.2 Publish tooling

`scripts/echo-mirror.sh` (or `nix run .#echo-mirror`) is the only new workflow
tool. It consumes `pkgs/components.nix`, the root `Cargo.toml`/`Cargo.lock`, and
the git index:

1. For each component, copy every tracked file under each member dir into
   `dist/mirrors/<id>/<same relative path>` (preserving layout, I6).
2. Copy root `Cargo.toml`, `Cargo.lock`, `.cargo/`, `.gitignore` verbatim.
3. Emit `component.nix` (identical to in-repo) and `flake.nix` from a checked-in
   template, substituting the component id / default package.
4. Write a `mirrors.lock.json` mapping `id -> { file -> sha256 }` plus the
   `flake-lib` pin and contract version.
5. `git init`/commit (and optionally push) each mirror repo.

It follows the `external-source-units.md` convention philosophy (research §5.3):
the convention is the discovery mechanism; the mirror is generated, never
hand-maintained.

### 10.3 Drift gate

Two layers:

- **Content gate (cheap, primary).** `checks.mirrors-fresh` regenerates each
  component into a temporary directory and diffs `mirrors.lock.json` against the
  checked-in copy. Any byte drift in a definition, manifest, or lock fails CI.
  This is the mirror analogue of `union-fresh` and the highest-value control
  (research §6.4).
- **Derivation gate (strong, CI).** With the mirror tree materialized (or the
  `mirrors` input present), assert
  `(compose.inRepo c)."<p>".drvPath == (compose.mirror c)."<p>".drvPath` under
  `basePolicy = component`, and `== (compose.inRepo c)."<p>".drvPath` under
  `union`. Instantiation only (no realization), so it is fast and IFD-free.

---

## 11. Validation gates and required spikes

### 11.1 Spikes (must pass before implementation proceeds)

- **E1 — preservation ⇒ source identity.** Generate a two-crate component
  mirror, run `nix path-info`/`nix derivation show` on `mkWorkspaceSourcePath`
  from monorepo vs mirror, assert equal `drvPath`/store path. (Directly tests
  Lemma 1.)
- **E2 — component base identity.** Assert `B_c(M).drvPath == B_c(R).drvPath`
  and that `--locked --offline --workspace` succeeds on a mirror whose root
  manifest lists absent members (member rewrite applied). (Lemma 2, research
  `locktest2` analogue.)
- **E3 — member drv equality.** Under `component` policy, assert
  `standalone.drvPath == composed-inRepo.drvPath == composed-mirror.drvPath` for
  a single-crate component and for the `{agent,manager}` component (the
  multi-crate, internal-edge case). (Theorems A/B.)
- **E4 — union injection.** Compose a mirror with the monorepo union base, build
  the member layer, assert the compile log contains **no**
  `Compiling
  <external>` line for crates already in the base (cache reuse) and
  that `cargo tree -e features -p m` matches the standalone. (Theorem A + §8.8.)
- **E5 — relative path inputs.** Confirm in-root `path:./pkgs/...` inputs work
  for tracked files, or fall back to `git+file:`/absolute `--override-input`;
  confirm `?dir=` and `flake=false` behavior in this repo (research §1.1–1.3).
  Gitignored `tmp/` paths must not be used as inputs.
- **E6 — drift gate efficacy.** Tamper one mirror byte; assert `mirrors-fresh`
  fails and the derivation gate catches any semantic change.
- **E7 — eval-cost measurement.** Compare `nix eval .#packages` with (a) direct
  in-repo imports, (b) `mirrors` `flake=false`, (c) N `flake=true` inputs, at 5
  and 24 components. This quantifies §14.
- **E8 — service split.** Confirm a Rust-only component flake evaluates without
  importing `service-module.nix` and that `nixosModules` still work when
  `flake-lib-service` is injected.
- **E9 — `.rs` locality.** Edit one member's `.rs`; assert the component base
  drv and all other components' bases are byte-stable; only the edited package
  and its dependents change. (L already gives this; re-verify with ECHO's source
  path.)
- **E10 — no IFD.** `nix eval --option allow-import-from-derivation false` on
  the monorepo and on a mirror.

### 11.2 Standard gates

- **V1** no IFD (E10).
- **V2** G10: `nix build` and `nix flake check` in a materialized mirror on a
  clean store (no monorepo).
- **V3** G11 composed == in-repo `drvPath` under `union`; standalone == composed
  under `component` (E3, E4).
- **V4** lock fidelity: `--locked` everywhere a member list is not
  dependency-changing; `cargo metadata --offline` diff shows no version change.
- **V5** mirror freshness (`mirrors-fresh`) and `mirrors.lock.json` contract.
- **V6** eval budget: E7 numbers recorded; no `flake=true` input for in-repo
  packages.
- **V7** binary semantics: `cargo tree -e features -p m` identical standalone vs
  composed (union policy).
- **V8** closure isolation: deployed package closure contains no artifact
  archive (existing gate).
- **V9** freshness diagnostic (optional, `union`): member layer has no external
  `Compiling` line; report residual count rather than failing (correctness does
  not depend on it under L semantics).
- **V10** all existing checks (`nix flake check`, `pkgOps`, formatter) remain
  green.

---

## 12. Platform gating

- `definition.<system>.<pname>.platforms` comes from the package `meta`. The
  component flake filters
  `available = filterAttrs (p: availableOn hostPlatform p)`.
- The component base is built only over the **host-available member subset**:
  `mkComponentBase { members = availableMembers host; }`. A Darwin-only member
  never enters a Linux `--workspace` and vice versa. This closes the latent
  native-input/`--workspace` failure research §4.6 warns about.
- The monorepo's existing `availableAttrs` filter stays; a component with no
  available members contributes no base and no packages on that host.
- `nativeBuildInputs`/`nativeCheckInputs`: per-member profile is part of the
  component base's arguments. Because the base is component-scoped, a member
  needing a native input does not poison other components' bases. (This is
  strictly better than L's unfiltered union base.)
- Cross-host components (rare) get one base per host; the composition keys the
  memo table by `(component, host)`.

---

## 13. Diagnostics and degradation

- `passthru.definition`, `passthru.component`, `passthru.base` on every package;
  `flake.echo.<system>` prints the component table, member dirs, chosen
  `basePolicy`, base drv, and whether the interface is in-repo/mirror-tree/
  mirror-flake.
- Degradation is `lib.warn`-not-throw, always with a clear fallback:
  - component graph missing/parse failure → fall back to the legacy per-package
    `manifest.nix` path (landed L) for that package;
  - mirror interface evaluation failure → fall back to the in-repo interface;
  - `flake-lib` contract mismatch → warn and use the monorepo lib for
    composition (standalone mirror remains responsible for its own pin);
  - unavailable host → omit the package (existing behavior).
- `basePolicy = "legacy"` restores landed L bit-for-bit
  (`cargoArtifactsBase =
    null`, `useWorkspaceDeps` as today). This is the
  rollback lever.
- The mirror freshness gate is fail-closed; the eval/instantiate derivation gate
  is fail-closed in CI but opt-out locally via an env var.

---

## 14. Honest costs and limits

### 14.1 Eval cost of many inputs

- `flake=true` inputs for all 24 components would evaluate 24 `nixpkgs`/ `crane`
  instantiations unless every one uses `follows`; even then, each flake's
  `outputs` runs. This is why ECHO's default for in-repo components is **direct
  import** and for mirrors is **`flake=false` + manual `outputs` invocation**:
  no per-component flake evaluation, no per-component lock entry, no version
  skew. `flake=true` is reserved for third-party consumption.
- The `mirrors` `flake=false` source tree is one input regardless of component
  count; `nix flake update` touches one entry. This keeps `flake.lock` small and
  stable.
- Direct import still evaluates each component definition, but it does so with
  the monorepo's already-instantiated `pkgs` and `pkgHelper` — roughly today's
  cost plus the contract wrapper.

### 14.2 Component base cost

- `basePolicy = component` is measured at ~2.05× external compiles for the
  current 5 members (`{0,65,216,233,239}` sum 753 vs union 367). At 24 members
  the curve is expected to worsen because more components recompile shared
  crates. ECHO does not pretend this is free; it makes `union` the default and
  `component` an explicit correctness mode. A middle path (group components
  whose member external signatures match into one base) is possible later but is
  the rejected Plan B headline; we do not rely on it.
- `basePolicy = union` keeps the 367 number and byte-identical composed
  replacement; it gives up only standalone/composed drv identity.

### 14.3 Lock and workspace handling

- Mirrors carry a verbatim lock (superset). `--locked` is safe because only the
  member list is rewritten. Extra lock packages are not an error.
- A peer dependency change changes the verbatim root manifest and therefore the
  component source/dummy source, so all component bases rebuild. The canonical
  component manifest (§9.2) is the documented localizer; it is optional and must
  be implemented in both monorepo and mirror by the same pure function, or drv
  equality breaks.
- `.cargo` config and `.gitignore` must be copied verbatim or
  `mkWorkspaceSourcePath`'s filter/dummy source diverges. The generator is the
  only place that knows this; the drift gate enforces it.

### 14.4 Complexity budget

| piece                                                                           | est. lines   | notes                                                          |
| ------------------------------------------------------------------------------- | ------------ | -------------------------------------------------------------- |
| `mkComponentFlake.nix` (contract, standalone outputs, `lib.mkPackage`)          | 150–200      | one file, pure, testable                                       |
| `mkComponentBase` + `cargoArtifactsBase` seam + `cargoWorkspaceMembersPrePatch` | 60–80        | in `pkg-helper.nix`                                            |
| `pkg-helper.nix` escape parameterization                                        | 30–40        | `repoRoot`/`treefmtConfig`/`src`                               |
| `pkgs/components.nix` + manifest `component` field                              | 30–50        | data                                                           |
| `lib/flake/components.nix` composition + `externalPackagesFor` thread           | 80–120       | replaces per-package build logic                               |
| `flake-lib` flake + template                                                    | 50–80        |                                                                |
| `scripts/echo-mirror.sh` + template + `mirrors.lock.json` writer                | 150–250      | generator + drift                                              |
| eval tests                                                                      | 100–150      | contract, graph closure, drv equality                          |
| **total**                                                                       | **~650–970** | comparable to REWEAVE's planner+emitter, but mostly data/moves |

Hard budget: if `mkComponentFlake` exceeds ~250 lines or the generator exceeds
~300, stop and simplify (drop canonical manifest, drop `flake=true` mode).

### 14.5 Honest limits

- **Standalone/composed drv identity is only free under `component`.** Under the
  default `union`, replacement is byte-identical but a standalone build is a
  different base; we prove semantic equality, not drv equality.
- **The mirror is not a "normal" flat repo.** It preserves `pkgs/tools/...`; raw
  `cargo build` from the mirror root fails without the rewrite. Users build with
  Nix. This is the deliberate price of drv equality (I6).
- **Global root-manifest churn** until the canonical manifest lands.
- **`flake-lib` extraction is a real prerequisite.** Until the four escapes are
  parameterized and the service stack split, mirrors cannot import the lib
  cleanly. This is the highest-risk work item.
- **Drift is a workflow risk, not a technical one.** The generator and gate are
  simple, but the team must run publish on every relevant change; the gate only
  catches omissions at CI time.
- **No solution to W10.** Component scoping reduces, not eliminates, residual
  external recompiles. The optional freshness gate reports it.

---

## 15. Staged migration

Each stage is independently shippable and reversible via `basePolicy`.

- **E0 — lib extraction, no behavior change.** Parameterize the four escapes,
  split the service stack, add `flake-lib/flake.nix`, add
  `cargoArtifactsBase`/`base` (default `null`) and
  `cargoWorkspaceMembersPrePatch`. `basePolicy = "legacy"`. Validate V10 and
  that all existing drv paths are unchanged.
- **E1 — component graph + component base.** Add `pkgs/components.nix`,
  `mkComponentBase`, and the `component` policy. Land E1/E2. Default remains
  `legacy`/`union`; `component` is opt-in.
- **E2 — in-repo component flakes.** Generate `component.nix` + `flake.nix` for
  components, starting with single-crate ones (`nats-http-bridge`,
  `nats-wrecking-ball`, `hello-rust`). Land E3 (single-crate) and E10.
- **E3 — monorepo composition via the contract.** Move `packages.nix` onto
  `lib/flake/components.nix`; in-repo components are imported and composed with
  the union base. Land E4, V3 (union), V7. `basePolicy = union` becomes default.
- **E4 — mirror generation + drift gate.** Land the generator, template,
  `mirrors.lock.json`, and `mirrors-fresh`. Publish single-crate mirrors. Land
  E6, V2.
- **E5 — multi-crate component + external swap.** Generate
  `{abird-host-agent, abird-host-manager}`, wire `externalPackagesFor` and the
  `mirrors` input, land E3 (multi-crate), E5, V3 (component).
- **E6 — optional refinements.** Canonical component manifest (churn
  localization), freshness diagnostic (V9), platform/host memoization,
  `flake=true` third-party mode, `hello-rust-isolated` retirement.

Rollback at any stage: `basePolicy = legacy` + remove the `mirrors` input
restores the pre-ECHO behavior; the generator/mirrors are additive.

---

## 16. Where ECHO beats the alternatives

- **vs the L-evolution (keep landed L, no flakes):** L cannot satisfy G10 at all
  (the 13 wrappers relativistically fall back to `rustPlatform`, research §5.1)
  or G11 without a composition seam. ECHO adds exactly one seam
  (`cargoArtifactsBase`) plus generated wrappers, and leaves the builder
  untouched.
- **vs REWEAVE:** REWEAVE's union manifest rewrite is precisely what makes
  semantics peer-dependent and blocks G10/G11 (research §3.2). ECHO keeps L's
  composition-independent `-p m` resolution and drops the rewrite, so a
  standalone component and the monorepo component are the same package by
  construction. REWEAVE's freshness gate is retained only as a diagnostic.
- **vs a "definition/adoption" alternative (monorepo adopts the mirror as the
  only builder):** that loses the in-repo fast path and forces every edit
  through the mirror repo. ECHO keeps the in-repo definition as the source of
  truth and the mirror as a generated copy; no fork, no divergence, and the
  union base still available for in-repo speed.
- **vs "extract lib and stop":** extraction alone gives G10's lib but not the
  component flake contract, the base injection, or the drift gate; ECHO packages
  those as the deliverables.

---

## 17. Acceptance criteria (definition of done)

1. `flake-lib` evaluates standalone; no `../..` escapes; Rust-only components do
   not import `service-module.nix`.
2. Every component has a generated `flake.nix` + `component.nix`;
   `nix flake
   check` and `nix build` succeed in a materialized mirror with no
   monorepo present (G10).
3. `checks.mirrors-fresh` passes; tampering fails it (drift control).
4. Under `basePolicy = component`,
   `standalone.drvPath == composed.drvPath ==
   inRepo.drvPath` for every
   component (E3).
5. Under `basePolicy = union`, `composed.drvPath == inRepo.drvPath` for every
   component, and `cargo tree -e features -p m` matches standalone (G11
   replacement).
6. `nix eval --option allow-import-from-derivation false` succeeds on the
   monorepo and all mirrors.
7. E7 eval-cost numbers recorded for 5 and 24 components; no in-repo
   `flake=true` input.
8. `basePolicy = legacy` reproduces landed L bit-for-bit.

---

## 18. References

- `tmp/design-f2/research.md` — flake mechanics, extraction escapes, base
  sharing, mirror workflow.
- `.agents/docs/notes/tooling/rust-build-graph-dual-mode-goals-2026-09.md` —
  G10/G11 and why REWEAVE is insufficient.
- `.agents/docs/plans/design-f-build-graph-2026-09.md` — REWEAVE (prior art;
  `cargoWorkspaceMembersPrePatch`, freshness gate, shard analysis).
- `lib/flake/pkg-helper.nix` — `mkWorkspaceSourcePath` (67),
  `mkCargoWorkspaceSource` (102), `rustWorkspaceMembers` (142),
  `mkRustWorkspaceSource` (167), `mkSharedRustDepsBase` (179),
  `mkCargoArtifactsJoin` (198), `cargoWorkspacePrePatch` (235), `repoRoot` (11),
  `repoFmtCheckCommand` (474), `mkTrunkProject` src default (1529),
  `mkRustDerivation` src default (2116), `mkRustDerivation` workspace mode
  (2235+), `memberLayer` (2400).
- `lib/flake/stack/package.nix`, `lib/flake/service-module.nix` — extraction
  coupling.
- `pkgs/manifest.nix`, `pkgs/tools/abird-host-{agent,manager}/default.nix`,
  `pkgs/examples/hello-rust-isolated` — current shapes.
- `tmp/design-f2/flake-exp/` — verified path/`flake=false`/`?dir=`/`follows`/
  `--override-input` primitives.
- Crane rev `73b9805`: `lib/mkDummySrc.nix` (content-addressed source, cleaned
  manifests, load-bearing output name), `lib/buildDepsOnly.nix`
  (`check`/`build`/`test --no-run`, `CRANE_BUILD_DEPS_ONLY`),
  `lib/findCargoFiles.nix` (walks present manifests, not workspace members).
