# FACET — Package Definitions with Pluggable Composers

Status: implementation-ready design (council 2, candidate E2). Scope: Rust build
graph under G10 (dual mode / mirroring) and G11 (seamless replacement). Builds
on landed Design L (`lib/flake/pkg-helper.nix`) and uses
`.agents/docs/notes/tooling/rust-build-graph-dual-mode-goals-2026-09.md` as the
goal statement. Read with `tmp/design-f2/research.md`.

One sentence: **separate the package _definition_ (pure, component-scoped data
with no monorepo knowledge) from the _build strategy_; give it a monorepo
composer (union base, maximum dedup) and a standalone composer (component base,
mirror-identical); make the component manifest canonical so both composers feed
cargo byte-identical inputs; generate mirrors from the definition and gate drift
plus derivation identity.**

---

## 0. Decision summary

| concern             | choice                                                                                                                                  |
| ------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| semantic unit       | the **path-connected component** `C(m)` (crates linked by internal `path=` deps); never the whole monorepo                              |
| definition          | pure eval data + pkgs-valued inputs; no `projectDir`, no `deps`, no `internalDeps`, no workspace knowledge                              |
| member resolution   | `-p m` against a **canonical generated component root manifest** + copied `Cargo.lock`; identical bytes in both modes                   |
| monorepo strategy   | whole-repo **union base** injected as `cargoArtifacts` (fast, 367 externals measured)                                                   |
| standalone strategy | **component base** keyed on `C(m)` (mirror-identical, ~2.05x measured)                                                                  |
| G11 adoption        | `externalPackagesFor` seam + package-flake output contract exporting the **declaration** and a `lib.mkPackage { pkgs; base; }` composer |
| `lib/flake`         | parameterize the 4 relative escapes; extract the **rust core** as an isolated flake; keep `service-module` out of core                  |
| mirrors             | generated in-tree under `mirrors/<name>/`; `mirror-fresh` (bytes) + `mirror-drv-eq` (drvPath) + `adoption-eq` gates                     |
| correctness         | component-local resolution ⇒ semantics are peer-independent by construction; union base is a pure memoization                           |

The single most important mechanical rule: **the root `Cargo.toml` a member
builds against is generated, canonical, and identical in both composers.** It is
not the monorepo root manifest and not the awk-rewritten copy. This is what
makes `mirror drv == in-repo drv` achievable and testable rather than
aspirational.

---

## 1. Architecture and module boundaries

```text
                      pure eval (no IFD, no derivations)
 repo root Cargo.toml ─┐
 member Cargo.toml   ──┼─▶ lib/flake/rust/component.nix  (planner)
 Cargo.lock          ──┘    ├─ members, glob expansion
                            ├─ internal path-dep components C(m)
                            ├─ used [workspace.dependencies] subset
                            └─ manifest facts ([workspace.package], [patch])
                                       │  Component
                                       ▼
 package declaration ────▶ lib/flake/rust/definition.nix   (schema + mkDefinition)
 (pkgs-valued inputs)         │  PackageDefinition
                              ▼
                   lib/flake/rust/manifest.nix  (canonical root manifest renderer)
                              │  TOML bytes
                              ▼
       ┌──────────────────────┴──────────────────────┐
       │                                             │
       ▼                                             ▼
lib/flake/rust/composer.nix                   lib/flake/rust/composer.nix
 buildMonorepo { base = unionBase }            buildStandalone { base = componentBase }
       │                                             │
       ▼                                             ▼
 unionBase (whole repo)                     componentBase (C only)
       \                                             /
        \─── same canonical componentSource ─────────/
                       │
                       ▼
       crane: buildDepsOnly → cargoBuild(-p m) → buildPackage(-p m)
```

Module boundaries:

| module                          | inputs                                                                | outputs                                                           | purity                                                  |
| ------------------------------- | --------------------------------------------------------------------- | ----------------------------------------------------------------- | ------------------------------------------------------- |
| `lib/flake/rust/component.nix`  | evaluator-visible `sourceRoot`, optional explicit root manifest attrs | `{ members, member, workspace, lock, cargoConfig }`               | pure; `readFile`/`fromTOML`/`readDir`/`pathExists` only |
| `lib/flake/rust/manifest.nix`   | component attrs                                                       | canonical `Cargo.toml` **string**                                 | pure                                                    |
| `lib/flake/rust/definition.nix` | declaration fn + `self`/`pkgs`/`lib`/`srv` + component                | `PackageDefinition`                                               | pure + pkgs values; validated                           |
| `lib/flake/rust/source.nix`     | `sourceRoot`, component                                               | `componentSource` derivation                                      | build-time only                                         |
| `lib/flake/rust/composer.nix`   | definition, `pkgs`, `base`                                            | derivation + passthru                                             | emits derivations                                       |
| `lib/flake/rust/mirror.nix`     | definition, `lib/flake` ref                                           | mirror file set                                                   | pure                                                    |
| `lib/flake/pkg-helper.nix`      | —                                                                     | generic derivation helpers; rust entry points delegate to `rust/` | —                                                       |

Nothing under `lib/flake/rust/` imports `service-module.nix`, `secrets.nix`,
`../../pkgs/...`, or any `../../` path. The service stack enters only through
the injected `srv` argument used by a declaration's `extraPassthru`, which is
the mirror's/vendored helper's job to supply (real stack in-repo, stub stack
standalone).

---

## 2. Package definition schema (pure eval, no IFD)

### 2.1 Shape

```nix
# lib/flake/rust/definition.nix — the value type
PackageDefinition = {
  schema = "package-definition/1";

  # identity — pure
  name    = "abird-host-agent";
  version = "0.1.0";

  # canonical component facts — pure; produced by the planner, never hand-written
  component = {
    key       = "c1f2…";                 # hash of sorted member dirs, mode-independent
    members   = [ "pkgs/tools/abird-host-agent" ];
    member    = "pkgs/tools/abird-host-agent";   # == self.memberDir, kept for the composer
    resolver  = "3";
    workspace = {
      dependencies = { /* used subset only, with default-features preserved */ };
      package      = { /* [workspace.package] */ };
    };
    patch     = { };
    replace   = { };
  };
  lock   = { file = "Cargo.lock"; contents = "<verbatim monorepo Cargo.lock>"; };
  cargo  = { config = { /* .cargo/config.toml if any */ }; };

  # build inputs — pkgs-valued, supplied by the declaration function
  nativeBuildInputs = [ ];
  buildInputs       = [ ];
  nativeCheckInputs = [ ];
  env               = { };
  checkEnv          = { };
  buildAttrs        = { };        # doCheck, postInstall, prePatch, ...

  # surface — pkgs/lib-valued
  meta          = { mainProgram = "abird-host-agent"; platforms = ...; };
  extraPassthru = { } | (pkg: { ... });   # e.g. { nixosModule = srv.mkModule {}; }

  # policy — pure
  platforms  = [ "x86_64-linux" ];   # optional host filter
  basePolicy = "auto";               # auto | union | component
};
```

Properties:

- **No monorepo knowledge.** No `projectDir` string, no `deps`, no
  `internalDeps`. The declaration cannot name a sibling package; the planner
  derives the component from `Cargo.toml` path edges.
- **No IFD.** Every read is a plain file behind `builtins.isPath`; the lock is
  read with `builtins.readFile`.
- **Deterministic.** All lists are sorted and deduped so `component.key` and the
  rendered manifest are hash-stable.

### 2.2 The author-facing API is a declaration function

`pkgs/<...>/definition.nix` (the only file the generator copies into a mirror)
is repo-agnostic:

```nix
# pkgs/tools/abird-host-agent/definition.nix
{ self, pkgs, lib, srv, ... }:
{
  name    = "abird-host-agent";
  version = "0.1.0";
  buildAttrs.doCheck = false;
  nativeCheckInputs = [ pkgs.rsync ];
  enableDevShell = true;
  meta = { mainProgram = "abird-host-agent"; platforms = lib.platforms.linux; };
}
```

`self` is supplied by the composer and is the only way the declaration learns
where it lives:

```nix
self = {
  memberDir   = "pkgs/tools/abird-host-agent";  # "." in a mirror
  component   = <planner result>;
  sourceRoot  = <path>;
  isStandalone = bool;
};
```

Because the declaration never mentions `memberDir`, the **same bytes** evaluate
in the monorepo and in a mirror. That is G10's no-divergence property, enforced
by copying the file.

### 2.3 The in-repo adapter is tiny

```nix
# pkgs/tools/abird-host-agent/default.nix
{ lib, pkgs, pkgHelper, ... }:
pkgHelper.mkRustPackage {
  declaration = import ./definition.nix;
  inherit lib pkgs;
}
```

`mkRustPackage` runs the planner, builds `self`, calls the declaration,
validates the definition, and dispatches to the composer. The author writes only
the declaration.

### 2.4 Definition validation

`validateDefinition` fails **at eval** for a missing/duplicate field, a member
not in `component.members`, a lock mismatch, or a `basePolicy` conflict. It is a
total function over the declaration and never reads a derivation (pure eval).

---

## 3. The planner (`component.nix`)

Pure, ~200–280 lines.

1. Read root `Cargo.toml` from `sourceRoot` (or use an explicit manifest attrs
   provided by a mirror). `fromTOML` + `readFile`.
2. Read `[workspace].members`; expand simple globs with `readDir` + `match`
   (research §14.1/§F2). Non-expandable globs degrade the package to the legacy
   path with a `lib.warn`.
3. For each member, read its `Cargo.toml`; collect entries from
   `[dependencies]`, `[dev-dependencies]`, `[build-dependencies]`, and
   `[target.<cfg>.*]`, both hyphen/underscore aliases.
4. Build the internal path-dep graph: an edge `a → b` when a dep entry has
   `path` resolving to member `b`'s dir (normalize `./`, trailing `/`, and
   `..`). Take the connected component `C(m)`.
5. Collect the **used** `[workspace.dependencies]` subset: the union over `C(m)`
   members of keys referenced with `workspace = true`. Preserve each entry
   verbatim (including `default-features = false`, `features`, `version`,
   `package`). Copy `[workspace.package]` wholesale; copy `[patch]`/`[replace]`
   only if they exist (they are global and small).
6. Resolve duplicate version families from `Cargo.lock`; a family collision
   inside a component degrades to solo/legacy with a warning (conservative).
7. Output `Component` with `key = hash (sort members)` and a fully rendered
   canonical manifest string (via `manifest.nix`).

No derivations, no import from a derivation, no `readDir` of a store path.

---

## 4. Canonical component source (the key to drv equality)

`source.nix` produces `componentSource` as a derivation, not by filtering the
root manifest away:

```nix
mkComponentSource = { pkgs, sourceRoot, component }:
  let
    # 1. content-addressed member tree, mode-independent
    members = builtins.path {
      path = sourceRoot;
      name = "facet-members";
      filter = path: type:
        gitignoreAllows path type
        && (
          rel == ".cargo" || hasPrefix ".cargo/" rel
          || (type == "directory" && isParentOf rel)   # ancestors of members
          || isUnder rel component.members
        );
    };
  in
  pkgs.runCommand "cargo-workspace-source" {
    # identical inputs in monorepo and mirror:
    inherit members;                     # builtins.path, content-hashed
    manifest = pkgs.writeText "Cargo.toml" (renderRootManifest component);
    lock = pkgs.writeText "Cargo.lock" component.lock.contents;
  } ''
    cp -a "$members"/. "$out"/
    install -m u+w "$manifest" "$out/Cargo.toml"
    install -m u+w "$lock" "$out/Cargo.lock"
  '';
```

Why this is load-bearing:

- `builtins.path { filter = keep component.members }` is content-hashed, so the
  monorepo and a byte-identical mirror produce the **same** `members` store path
  even though their roots differ. This is the mechanism that makes drv equality
  possible; `research.md` §4.4 already relies on content hashing for vendor and
  dummy identity.
- The generated root manifest and lock are pure `writeText` values, so they are
  identical in both modes.
- Output basename is `cargo-workspace-source`, satisfying crane's
  `mkDummySrc`/fingerprint invariant (`research.md` §4.4; Design L invariant 3).
- The mirror preserves the monorepo-relative layout (`pkgs/tools/...`), so
  `component.members` strings are identical across modes.

`mkDummySrc { src = componentSource; }` and the member
`cargoBuild { src =
componentSource; }` both unpack to
`/build/cargo-workspace-source`.

The legacy `mkCargoWorkspaceSource`/`cargoWorkspacePrePatch` awk remains only
for the rollback path; the E2 path does not use it.

---

## 5. The two composers and exact cargo invocations

`composer.nix` exposes one function parameterized by the artifact base:

```nix
build = {
  pkgs, definition, base,            # base = unionBase | componentBase | null
  buildMode,                         # "monorepo" | "standalone"
}: drv
```

### 5.1 Shared building blocks

```nix
componentBase = craneLib.buildDepsOnly {
  dummySrc = craneLib.mkDummySrc { src = componentSource; };
  pname = "facet-${definition.component.key}-deps";
  version = "0.1.0";
  cargoExtraArgs = "--locked --offline --workspace";
  cargoLockContents = definition.lock.contents;
  cargoVendorDir   = craneLib.vendorCargoDeps { cargoLockContents = ...; };
  nativeBuildInputs = definition.component.nativeProfile or [];
  env = { CARGO_NET_OFFLINE = "true"; };
};
```

`componentBase` depends **only** on `C(m)` and on the lock; it is identical in
both composers. It is the mirror-identical artifact.

The monorepo union base (landed L `mkSharedRustDepsBase`) is:

```nix
unionBase = craneLib.buildDepsOnly {
  dummySrc = craneLib.mkDummySrc { src = wholeRepoSource; };  # real root manifest, all members
  pname = "abird-rust-workspace";
  version = "0.1.0";
  cargoExtraArgs = "--offline --workspace";
  cargoLockContents = rootLockContents;
  cargoVendorDir = craneVendorDir;
  env = { CARGO_NET_OFFLINE = "true"; };
};
```

### 5.2 Artifact prefix and internal-dep chaining

The planner knows the component's internal edges, so chaining is automatic:

```nix
internalDeps = planner.internalDepsOf component definition.component.member;  # e.g. [ agent ]

prefixFor m =
  if base != null then base
  else if buildMode == "monorepo" then unionBase
  else componentBase;

dependencyArtifacts m =
  if internalDeps == [] then prefixFor m
  else if builtins.length internalDeps == 1
       then (builtins.head internalDeps).passthru.memberLayer   # already chains to prefix
  else mkCargoArtifactsJoin { deps = prefixFor m :: map memberLayer internalDeps; };
```

### 5.3 Member layer (artifacts only, one compile per crate)

```nix
memberLayer m = craneLib.cargoBuild (common m // {
  pname = "${m.name}-layer";
  src = componentSource;
  cargoArtifacts = dependencyArtifacts m;
  cargoExtraArgs = "--offline -p ${m.name}";
  doInstallCargoArtifacts = true;
  doCheck = false;
  nativeBuildInputs = definition.nativeBuildInputs ++ definition.buildInputs;
  env = { CARGO_NET_OFFLINE = "true"; } // definition.env;
});
```

`--offline` (not `--locked`) because the generated manifest is canonical and the
lock is copied; every used package already exists in the lock. This mirrors
landed L's member invocation (`research.md` §3.1).

### 5.4 Deployed package (no artifact export)

```nix
pkg m = craneLib.buildPackage (common m // {
  pname = m.name;
  src = componentSource;
  cargoArtifacts = memberLayer m;
  cargoExtraArgs = "--offline -p ${m.name}";
  doInstallCargoArtifacts = false;          # runtime closure stays lean (L invariant)
  nativeBuildInputs = definition.nativeBuildInputs ++ definition.buildInputs;
  nativeCheckInputs = definition.nativeCheckInputs;
  doCheck = definition.buildAttrs.doCheck or false;
  postInstall = definition.buildAttrs.postInstall or "";
  meta = definition.meta;
  env = { CARGO_NET_OFFLINE = "true"; } // definition.env;
});
```

### 5.5 Checks

```nix
fmt   = craneLib.cargoFmt   (common m // { cargoExtraArgs = "--offline -p ${m.name}"; });
lint  = craneLib.cargoClippy(common m // {
          cargoArtifacts = memberLayer m;
          cargoExtraArgs = "--offline -p ${m.name}";
          cargoClippyExtraArgs = "-- -D warnings";
          nativeBuildInputs = definition.nativeCheckInputs;
        });
test  = craneLib.cargoTest  (common m // {
          cargoArtifacts = memberLayer m;
          cargoExtraArgs = "--offline -p ${m.name}";
          doCheck = true;
          nativeCheckInputs = definition.nativeCheckInputs;
          preBuild = exportEnv definition.checkEnv;
        });
```

The base primes dev/test units (`buildDepsOnly` runs `cargo test --no-run`), so
checks reuse them (Design L W5/P2-e).

### 5.6 Composer dispatch

| build mode                                | base      | result                                                                                  |
| ----------------------------------------- | --------- | --------------------------------------------------------------------------------------- |
| `buildMonorepo { base = unionBase; }`     | union     | fast; semantics component-local; artifacts may recompile residual                       |
| `buildMonorepo { base = componentBase; }` | component | **drv-identical to standalone**; used by the equality gate and by adoption-with-sharing |
| `buildStandalone {}`                      | component | mirror-identical; independent reproducibility                                           |
| `buildStandalone { base = unionBase; }`   | injected  | adoption fast path: external definition + monorepo cache                                |

`buildMonorepo` and `buildStandalone` are the _same function_ with different
base selection; there is no semantic branch.

---

## 6. G10/G11: satisfaction, adoption, and flake contract

### 6.1 G10 (dual mode)

- The declaration file is repo-agnostic and is copied verbatim by the generator.
- The component root manifest, lock, and source tree are generated by pure
  functions from the component, so in-repo and mirror builds consume identical
  cargo inputs by construction.
- The standalone composer supplies `self = { memberDir = "."; component; ... }`
  and builds with `componentBase`. No monorepo path appears.
- `lib/flake` is optional: until extracted, mirrors vendor the parameterized
  helper (bytes tracked per `shared-test-areas.md`); after extraction, mirrors
  pin the `lib/flake` flake input.

### 6.2 G11 (seamless replacement) — three adoption modes

**Seam.** Thread a defaulted `externalPackagesFor` through the assembly:

```nix
# flake.nix (consumer)
outputs = inputs:
  (import ./lib/flake/root.nix {
    inherit inputs repositoryConfig repositoryInventory repoChecksFn;
    externalPackagesFor = system: {
      abird-host-agent = inputs.abird-host-agent;   # a package flake
    };
  }).outputs;
```

`root.nix → default.nix → withPkgs → packages.nix` passes
`externalPackagesFor system` to the registry resolution. This matches the
council-verified minimal seam (research §1.4).

**Mode A — derivation adoption (fast, no cache sharing).**

```nix
if external ? name then external.${name}.packages.${system}.default
else callPackage entry.path ...
```

Same semantics; the external's component base is separate, so its externals are
compiled again unless the monorepo base is injected. Documented trade-off.

**Mode B — base-injected adoption (fast + shared cache).**

The package flake exports a pkgs-parametric composer:

```nix
# package flake (generated)
outputs = { self, nixpkgs, flake-utils, libflake, crane }:
{
  lib.mkPackage = { pkgs, base ? null }:
    (import "${libflake}/rust/composer.nix").buildStandalone {
      inherit pkgs base;
      definition = mkDefinition { ... };
    };
  packages = ... eachSystem ... { default = self.lib.mkPackage { pkgs = ...; }; };
  packages.<system>.definition = <PackageDefinition>;   # pure data
  packages.<system>.declarationPath = "${self}/definition.nix";
}
```

The monorepo calls
`ext.lib.mkPackage { pkgs = monorepoPkgs; base = unionBase; }`. The external's
component source is byte-identical to the in-repo one (generated from the same
declaration), so the resulting drv is **identical** to the in-repo package (see
§7 gate). Sharing is exact.

**Mode C — declaration adoption (full merge).**

The monorepo imports the external declaration directly and composes it with its
own planner and base:

```nix
externalPackagesFor = system: {
  abird-host-agent = { declaration = import "${inputs.abird-host-agent}/definition.nix"; };
};
# packages.nix:
if external.${name} ? declaration
then pkgHelper.mkRustPackage { declaration = external.${name}.declaration; inherit pkgs lib; }
else ...
```

This is the strongest "merge seamlessly": the external is treated exactly as an
in-repo package definition, with the monorepo's `self`, planner, and base.
Version skew is one flake input + `follows` for nixpkgs/crane/libflake.

**Contract summary (what a package flake MUST export):**

| output                                | required    | purpose                        |
| ------------------------------------- | ----------- | ------------------------------ |
| `packages.<system>.default`           | yes         | standalone derivation          |
| `packages.<system>.definition`        | recommended | pure definition data for gates |
| `packages.<system>.declarationPath`   | optional    | file path for Mode C           |
| `lib.mkPackage { pkgs, base ? null }` | optional    | base seam (Mode B)             |
| standard `apps`/`checks`/`devShells`  | yes         | `mkStdFlakeOutputs`            |
| `nixosModules`                        | if declared | passthru module                |

---

## 7. Proof obligations and semantic equivalence

### 7.1 The drv-equality gate (G10)

```nix
checks.facet-mirror-drv-eq.<name> =
  pkgs.runCommand "facet-mirror-drv-eq-${name}" {} ''
    test "${standalone.${name}.drvPath}" = "${monorepoComponentMode.${name}.drvPath}"
    touch "$out"
  '';
```

where

- `standalone = composer.buildStandalone { pkgs; definition; base = null; }`,
- `monorepoComponentMode = composer.buildMonorepo { pkgs; definition; base = componentBase; }`.

Equality holds because: `componentSource` is content-identical (§4),
`componentBase` is a pure function of it, `memberLayer` chains the same
planner-derived internal edges, and `pkg` has identical attrs. Nix hash-conses
the whole chain. This is stronger than semantic equivalence and is a CI gate.

### 7.2 Semantic equivalence argument (G11)

Let the _resolution_ `R(m)` be the cargo unit graph selected by `-p m`. `R(m)`
is a function of:

1. the member `Cargo.toml` bytes,
2. the effective workspace manifest (`[workspace.dependencies]`,
   `[workspace.package]`, `[patch]`/`[replace]`, `members`, `resolver`),
3. `Cargo.lock` bytes,
4. toolchain/rustc/cargo versions, target triple, and profile/`RUSTFLAGS`,
5. the `-p m` selection.

Both composers supply (1)–(5) with identical bytes/values: the declaration is
copied verbatim; the canonical root manifest and lock are generated by the same
pure function in both modes; `pkgs.craneLib`, rustc, and target come from the
same `pkgs` under `follows`; and both run `--offline -p m`.

Therefore `R_inrepo(m) = R_standalone(m)`. The injected `base` is a _memoization
of compiled units_, not part of `R`: cargo decides freshness per unit from the
unit fingerprint (features, profile, toolchain, source). When the injected
base's unit has a different feature set than `R(m)` requests, cargo **rebuilds**
that unit; it never substitutes a mismatched unit. Hence the linked artifact is
a function of `R(m)`, not of the base, and the union base cannot change
semantics. This is exactly landed L's argument (`research.md` §3.1) extended to
the mirror.

The one way the argument fails is a manifest-byte divergence; `mirror-fresh`
(§9) and the `componentSource` content hash close that.

### 7.3 Gates that make the proof executable

- `facet-mirror-fresh`: regenerated mirror bytes == committed.
- `facet-mirror-drv-eq`: standalone drvPath == monorepo component-mode drvPath.
- `facet-adoption-eq`: external declaration composed via monorepo == in-repo
  drv.
- `facet-union-fresh`: member layer built on the union base recompiles no
  _external_ crate not explained by the polarity/feature residual (Design F's
  `union-fresh` detector, reused).
- `facet-component-base-identity`: all component-mode packages report the
  component base for their key.

---

## 8. Sharing and cost analysis

Measured (research §4.5, `tmp/design-f/final-plan.md`), 5 members:

| strategy                     | externals compiled              | mirror-identical        | G11 cache sharing   | semantics                  |
| ---------------------------- | ------------------------------- | ----------------------- | ------------------- | -------------------------- |
| **union base** (L)           | 367                             | no                      | via base injection  | component-local (binaries) |
| **component base** (B-comp)  | 753 (`{0,65,216,233,239}`)      | yes                     | exact               | component-local            |
| **base-as-input** (B-shared) | 367 + component base on mirrors | only with injected base | exact when injected | component-local            |

FACET's position:

- **Default monorepo = union base.** Fast; preserves landed L's measured
  behavior and `.rs` locality; correctness from §7.2.
- **Mirror = component base.** Self-contained and reproducible with no peers.
- **Adoption = base injection.** The monorepo passes `unionBase` into the
  external's composer, so the external reuses the monorepo's compiled deps and
  the drv equals the in-repo one. This is the "ideally same cache sharing"
  clause of G11, delivered without forcing the union into the standalone flake.
- **Equality gate = component base.** A CI-only instantiation, not the daily
  build, so the 2.05x is paid only where the proof requires it.

Cost at 24 members: the union base stays ~constant per external (1x), which is
the scalable axis. Component bases grow with the number of disjoint
feature/components; up to 24 singleton components is the worst case. FACET does
not pay that by default and makes the trade-off explicit (`basePolicy`).

Union-vs-base-as-input difference: with the union base the monorepo is fast but
a standalone mirror alone recompiles its own deps; with base-as-input the mirror
is _not_ independently reproducible at the same drv unless the base is supplied.
FACET removes the conflict by keeping the standalone build on the component base
(always reproducible) and injecting the union base only at adoption time.

---

## 9. Standalone workspace handling

| concern                          | handling                                                                                                                                          |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| `[workspace.dependencies]`       | component-used subset, preserved verbatim (features, `default-features`, `version`, `package`); no flattening, so polarity is exact               |
| `Cargo.lock`                     | copied verbatim; the resolution source; extra entries are inert. Optional future component-filtered lock is a follow-up                           |
| path deps                        | component closure includes all path-connected members; paths preserved because the mirror keeps the monorepo-relative layout; no hand `deps` list |
| `[workspace.package]`            | copied wholesale (small)                                                                                                                          |
| `[patch]`/`[replace]`            | copied; a conflict inside a component degrades that package to solo/legacy                                                                        |
| resolver                         | copied (`resolver = "3"`)                                                                                                                         |
| `.cargo/config.toml`             | preserved in `componentSource` (fingerprint-relevant, research §F4.4)                                                                             |
| `default-features = false`       | never widened because member manifests are copied, not union-rewritten (this is the deliberate difference from REWEAVE)                           |
| external `[features]` activation | planner detects `dep:<ext>`/`<ext>/<feat>`; such members are their own component (solo), preserving exact activation                              |

The base uses `--locked --offline --workspace`; the member uses
`--offline -p m`. Spike S2 confirms `--locked` tolerates the copied lock with a
member subset; if a cargo version rejects unused entries, the fallback is
`--offline` on the base (still version-pinned by the copied lock).

---

## 10. `lib/flake` extraction

### 10.1 Prerequisites (must land first)

1. Parameterize the four relative escapes in `pkg-helper.nix`:
   - `:11 repoRoot = builtins.toString ../..` → `repoRoot ? null`, derived from
     `src`; throw only if a caller needs it without `src`.
   - `:474 ${../../treefmt.toml}` → `treefmtConfig ? null`; repo-fmt check
     commands degrade (warn) when null.
   - `:1529` and `:2116` default `src = ../..` → required `src` (or `.` for the
     standalone composer), removing the silent `/nix` misresolution (research
     §2.1, §1.2).
2. Keep `service-module.nix` out of the rust core. `stack/package.nix` becomes a
   thin composition: `rust/` core + service stack, imported only by in-repo
   flakes and by mirrors whose declarations use `srv`.

### 10.2 Target layout

```text
lib/flake/
  flake.nix               # isolated library flake
  rust/{component,manifest,definition,source,composer,mirror}.nix
  pkg-helper.nix          # generic helpers + delegation into rust/
  stack/package.nix       # legacy in-repo service composition
```

`lib/flake/flake.nix` inputs: `nixpkgs`, `crane`, `flake-utils`. Outputs:
`lib.rust`, `lib.pkgHelper`, `lib.mkFlakeOutputs`. No `../../` escapes, no
`pkgs/manifest.nix` import at module scope; composition stays injected (research
§2.3).

### 10.3 Two adoption tracks

- **Vendored (lower risk, start here).** Mirrors copy `lib/flake` bytes and use
  a parameterized helper. `shared-test-areas.md` already makes byte-identical
  multi-repo areas a proven discipline. A drift check compares hashes.
- **Pinned flake input.** After extraction, mirrors depend on `libflake` and use
  `follows` for `nixpkgs`/`crane`. Skew is controlled by the pin; a mirror can
  lag intentionally.

FACET plans the vendored track as the migration default and the pinned input as
the end state; the generated `flake.nix` template is identical in both except
for the `libflake` input line.

---

## 11. Mirror generation and drift control

### 11.1 Generator

`lib/flake/rust/mirror.nix` is a pure function producing the expected file set:

```nix
mkMirrorFiles = { definition, memberDir, libflakeRef }:
{
  "definition.nix"  = <verbatim copy of pkgs/<...>/definition.nix>;
  "Cargo.toml"      = renderRootManifest definition.component;   # canonical, pure
  "Cargo.lock"      = definition.lock.contents;                  # verbatim
  "flake.nix"       = <generated template, §6.2>;
  "flake.lock"      = <pinned libflake/nixpkgs/crane>;
  ".cargo/config.toml" = optional;
};
```

The generator commits the tree under `mirrors/<name>/` in the monorepo. The
mirror repo is created by copying `mirrors/<name>/` (plus `.gitignore`); no
human edits the generated files. The declaration is the only shared
hand-authored byte, and it is copied, never re-typed.

### 11.2 Drift gate

```nix
checks.facet-mirror-fresh =
  pkgs.runCommand "facet-mirror-fresh" {} ''
    diff -ru --exclude=flake.lock \
      ${mkMirrorTree} ${./mirrors}
    touch "$out"
  '';
```

Any hand-edit or stale generated file fails CI. `flake.lock` is excluded from
byte-diffing only because Nix rewrites it on input changes; a second
`facet-mirror-lock-fresh` resolves and compares the locked revs.

### 11.3 Derivation and adoption gates

Covered in §7.3. Together they turn G10/G11 from a hope into three CI checks.

---

## 12. Dev-dependencies, checks, platform gating

- **Dev-deps:** part of the component manifest and lock, so the mirror carries
  them; `componentBase` primes normal + dev/test units (`buildDepsOnly` runs
  `cargo test --no-run`). Member checks inherit `memberLayer`, so no test-target
  recompile.
- **Native inputs:** `nativeBuildInputs`/`buildInputs` that externals need are
  part of the **component profile** and are an input to `componentBase`; the
  profile is identical across modes by construction. `nativeCheckInputs` stay on
  the member/check layer and do not affect sharing. A per-member native input
  that affects only externals would mis-key the base — the same latent gap as L
  (`research.md` §4.6) — documented; a future refinement is per-component
  profiles keyed by member.
- **Checks:** `fmt`/`lint`/`test` run against the canonical component source;
  `lint`/`test` inherit `memberLayer`. All run `-p m`.
- **Platform gating:** definitions declare `meta.platforms`; `availableAttrs`
  already filters unsupported hosts. The planner may exclude platform-gated
  members from a component's base on a host (bases are per-host, so this is
  safe); today all Rust members are Linux and the base uses the full component.
  Darwin packages build with `componentBase` on Darwin; `lib/flake` tests stay
  Linux-gated as today.

---

## 13. Diagnostics and degradation

- **Observability:** `passthru.definition`, `passthru.component`,
  `passthru.componentBase`, `passthru.base`, `passthru.memberLayer`, and a
  `flake.rustComponents` output listing components, members, used workspace
  deps, component keys, and predicted base counts.
- **Degradation (warn, never throw at eval):**
  - non-expandable glob member → that package uses the legacy per-package path;
  - manifest parse failure → legacy path for the dependent members;
  - duplicate version family / `[patch]` conflict → component split or solo;
  - missing lock content for a non-path source → legacy fallback;
  - `craneLib == null` (non-crane platform) → `rustPlatform.buildRustPackage`
    fallback (unchanged);
  - `projectDir`-shaped legacy call (`build != null`, isolated) → unchanged.
- **Rollback:** a per-package `basePolicy = "legacy"` (or
  `useWorkspaceDeps =
  false`) restores landed L bit-for-bit.

---

## 14. Staged migration

1. **E0 — planner diagnostic.** Land `rust/component.nix` +
   `flake.rustComponents`; no build change. Validate that planner components
   equal the hand-declared `projectDir`/`deps`/`internalDeps`.
2. **E1 — definition schema.** Land `definition.nix`; convert the 5 Rust
   packages to `definition.nix` + adapter; expose `passthru.definition`. Builds
   still use landed L. No behavior change.
3. **E2 — canonical component source + composers.** Land `source.nix`,
   `manifest.nix`, `composer.nix`; add the `base`/`cargoArtifacts` seam; switch
   the member build to the canonical component source; keep the union base for
   the monorepo. Verify `.rs` locality and `union-fresh`.
4. **E3 — `lib/flake` split.** Parameterize the four escapes; extract `rust/`;
   add `lib/flake/flake.nix`; add the standalone composer and the generated
   mirror template. Land `facet-mirror-fresh`.
5. **E4 — adoption seam.** Thread `externalPackagesFor`; add Mode A/B/C and
   `facet-adoption-eq`.
6. **E5 — migrate the 13 in-tree package `flake.nix`** to the generated mirror
   template (or replace them with `mirrors/<name>/`).
7. **E6 — pinned `libflake` input** in mirrors (replacing vendoring); `follows`
   nixpkgs/crane.

Fallback at every step: `basePolicy`/legacy path.

---

## 15. Validation spikes (must pass before/during implementation)

| id  | spike                                      | pass condition                                                                                 |
| --- | ------------------------------------------ | ---------------------------------------------------------------------------------------------- |
| S1  | pure planner reproduces components         | `{agent,manager}` one component; others singleton; no IFD                                      |
| S2  | canonical root + copied lock builds        | `--locked --offline --workspace` base and `--offline -p m` member; lock unchanged              |
| S3  | `componentSource` identity                 | monorepo vs synthetic mirror `members`/`componentSource` store paths equal                     |
| S4  | **mirror drv == in-repo** (component mode) | `drvPath` equality for every Rust package                                                      |
| S5  | union residual                             | `union-fresh` green or the known residual only                                                 |
| S6  | adoption eq                                | external declaration via monorepo + injected base == in-repo drv                               |
| S7  | mirror drift                               | hand-edit fails `facet-mirror-fresh`; regeneration passes                                      |
| S8  | `lib/flake` isolation                      | mirror evaluates `--option allow-import-from-derivation false` and builds without the monorepo |
| S9  | `.rs` locality                             | base drv byte-stable after a content edit                                                      |
| S10 | path-input swap                            | `--override-input` swaps a package with no file edit (research §1.1)                           |

Standard gates reuse Design L's V1–V11 (no IFD, zero residual, lock fidelity,
polarity, closure isolation, eval tests).

---

## 16. Complexity budget

| new/changed                    | size     | note                                                         |
| ------------------------------ | -------- | ------------------------------------------------------------ |
| `rust/component.nix`           | ~200–280 | pure; unit-testable with eval tests                          |
| `rust/manifest.nix`            | ~60      | `lib.generators.toTOML`                                      |
| `rust/definition.nix`          | ~80      | schema + validation                                          |
| `rust/source.nix`              | ~50      | `builtins.path` + `runCommand`                               |
| `rust/composer.nix`            | ~200     | wraps existing crane calls                                   |
| `rust/mirror.nix`              | ~120     | generated file set                                           |
| `pkg-helper.nix` delta         | ~80      | delegation + base seam + escape parameters                   |
| generated `flake.nix` template | ~40      | per mirror                                                   |
| **net package-author surface** | **−**    | `projectDir`, `deps`, `internalDeps` disappear from packages |

Hard rule: if the planner exceeds ~400 lines, stop and degrade; correctness does
not depend on planner cleverness (the gates are the backstop).

---

## 17. Honest limits

1. **Drv equality is component-base-only.** Union mode is semantically equal but
   not artifact-identical; the equality gate runs a component-mode
   instantiation.
2. **Copied whole lock** means lock churn touches all mirrors. Generation makes
   this invisible to authors; a component-filtered lock is future work.
3. **Planner fidelity.** Unusual Cargo constructs (renames, `artifact`/`lib`
   deps, target tables, duplicate version families) can under-approximate the
   component; the conservative splits and the `union-fresh` gate bound the risk,
   and the legacy fallback is always available.
4. **Transitive `default-features` widening** is invisible to pure eval (the
   lock has no feature data). FACET does not introduce it (no union rewrite) but
   the union base still causes recompiles; it cannot change the component's
   binary because cargo rebuilds mismatched units.
5. **`lib/flake` extraction** remains blocked until the four escapes are removed
   and `service-module` is kept out of core; mirrors vendor the helper until
   then.
6. **Native-input profiles are component-level**; a member whose externals need
   a unique native input would mis-key the shared base (pre-existing L gap,
   narrower under components).
7. **Mirroring to a real repo needs a push step.** `mirrors/<name>/` in-tree is
   the source of truth; the gate covers it, but a release script must copy it to
   the external repo and open the update.
8. **Cross-repo version skew** is a pin/follows problem, not solved by identity:
   the `definition.nix` and `libflake` rev must be compatible. The mirror's
   `definition.nix` is copied, so only the helper pin can drift; a `libflake`
   ABI version is part of the contract.

---

## 18. Where FACET beats the alternatives

- **vs L-evolution:** L keeps hand-declared `projectDir`/`deps`/`internalDeps`
  and one monorepo-keyed base. FACET derives the component, removes the
  hand-synced fields, gives a genuine standalone path, and replaces "hopefully
  same" with a drv-equality gate. G10/G11 become properties, not aspirations.
- **vs mirror-first:** mirror-first makes each mirror the source of truth and
  forces every change to span repos (high churn, hard cross-package refactors).
  FACET keeps the monorepo authoritative, generates mirrors, and gates drift.
- **vs REWEAVE / union-forcing:** rewriting member manifests to a union makes
  semantics peer-dependent (disqualifying under G11). FACET keeps `-p m`
  component-local and treats the union base strictly as a cache memoization, so
  standalone and merged resolve identically by construction.

---

## 19. References

- `tmp/design-f2/research.md` — flake mechanics, extraction escapes, sharing
  measurements, mirror workflow.
- `.agents/docs/notes/tooling/rust-build-graph-dual-mode-goals-2026-09.md` —
  G10/G11.
- `.agents/docs/plans/design-f-build-graph-2026-09.md` — REWEAVE prior art
  (union rewrite; rejected as the spine, `union-fresh` gate reused).
- `.agents/docs/plans/design-l-implementation-2026-09.md` — landed L mechanics
  and invariants.
- `.agents/docs/design-patterns/package-project-boundaries.md` — desired
  standalone flake shape.
- `.agents/docs/design-patterns/external-source-units.md` — generation +
  convention-as-discovery + drift discipline.
- `.agents/docs/design-patterns/shared-test-areas.md` — byte-identical
  multi-repo areas.
- `lib/flake/pkg-helper.nix` — `mkWorkspaceSourcePath`,
  `mkCargoWorkspaceSource`, `rustWorkspaceMembers`, `mkRustWorkspaceSource`,
  `mkSharedRustDepsBase`, `mkCargoArtifactsJoin`, `cargoWorkspacePrePatch`,
  `mkRustDerivation`, `memberLayer`.
- `lib/flake/packages.nix`, `lib/flake/root.nix`, `lib/flake/default.nix`,
  `lib/flake/stack/package.nix`, `pkgs/manifest.nix`, `overlays/default.nix`.
- `tmp/design-f2/flake-exp/` — verified path-input/follows/override mechanics.
