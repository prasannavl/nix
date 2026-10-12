# Multi-ecosystem build fabric — coherent plan (Rust · Go · Node · Deno · Python · C++)

Status: design. Expands the Rust Capsule/Ledger/Unit-DAG design into one
overarching, ecosystem-agnostic build and cache architecture, and assesses
whether the repo should be designed around it. Nothing implemented.

---

## 0. Verdict up front

**Yes, one overarching fabric is sound — provided the core is small and
ecosystem-agnostic, and each ecosystem is an adapter with a declared _capability
tier_ and a _fail-closed fallback_.** The single deep idea is:

> **The ecosystem's own tool resolves; the fabric records resolution, caches it
> by exact unit identity, and never manufactures equality for performance.**

This is exactly the Rust design ("Cargo defines equality, Nix caches it"),
generalized: _every_ ecosystem has a resolver, a lock, and a notion of a build
unit; the fabric captures the resolver's output once (committed), content-
addresses units, and builds each unit with that ecosystem's executor.

The soundness caveat is real but bounded: Rust, Go, and Deno are
capture-friendly and near-hermetic; Node is mostly capture-friendly; Python is
conditional (wheels are clean, sdists are not); C++ has no ecosystem lock and is
the weakest. The fabric must therefore **not** pretend uniformity. It declares a
capability tier per package and degrades to a native-tool "one opaque build"
mode when a unit cannot be faithfully expressed. That is the same fail-closed
move the Rust design uses per capsule.

---

## 1. The generic fabric (ecosystem-agnostic core)

### 1.1 Concepts

| concept                 | definition (ecosystem-agnostic)                                                                                                                                                                                                                              |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Declaration**         | The handwritten manifest(s) that define a project's dependencies: `Cargo.toml`, `go.mod`, `package.json`, `deno.json`, `pyproject.toml`, `CMakeLists.txt`/`meson.build`/`conanfile`. The only handwritten dependency graph.                                  |
| **Capsule**             | A resolution scope: the minimal set of declarations + lock needed to resolve one root (`closure(P)` in the Rust design). Peers are structurally absent.                                                                                                      |
| **Resolver (producer)** | The ecosystem's own resolver, run by a pinned producer, producing the exact resolved unit graph. The producer **captures**; it does not reimplement.                                                                                                         |
| **Lock**                | The ecosystem lock is the resolution authority: `Cargo.lock`, `go.sum` (+ MVS), `package-lock.json`/`pnpm-lock.yaml`/`yarn.lock`, `deno.lock`, `uv.lock`/`poetry.lock`/hashed requirements, CMake File API + a pinned toolchain (C++ has no universal lock). |
| **Unit**                | One exact resolved build step with a content-addressed descriptor (§1.3).                                                                                                                                                                                    |
| **Ledger**              | A committed, content-addressed store of unit descriptors (`ledger/<unitId>.json`). Identical units from different capsules are the same entry and therefore the same derivation.                                                                             |
| **Shard / plan**        | One committed file per `(capsule, purpose, target, profile)` selecting `unitId`s and holding freshness stamps. Plan data is never a unit input.                                                                                                              |
| **Executor**            | The per-ecosystem rule that realizes a unit (`rustc`/`cargo`, `go build`, `cc`/`cmake`/`ninja`/`meson`, wheel unpack, node tree copy, deno bundle).                                                                                                          |
| **Assembly**            | Turns root units into the deliverable (binary, bundle, `node_modules`/site, virtualenv, install tree) and applies packaging, overlays, wrappers, module outputs.                                                                                             |
| **Edges**               | Three strictly separate kinds (§1.4): resolver edges, compile overlays, Nix package edges.                                                                                                                                                                   |
| **Mode**                | Per capsule: `unit` (exact-unit derivations), `<native>` (one opaque native-tool build, e.g. `cargo`/`npm`/`pip`/`cmake`), `legacy` (bit-for-bit rollback). Fail-closed.                                                                                     |
| **Provider / mirror**   | Per-package flake contract and replacement seam; byte-identical mirror ⇒ cache hit.                                                                                                                                                                          |
| **Contracts**           | Declared, per-ecosystem: **toolchain**, **native/ABI policy**, **compile environment** — keyed by `(package, target/ABI)` where needed.                                                                                                                      |

### 1.2 Invariants (generalized from the Rust design)

1. No evaluation imports a derivation result (no IFD).
2. Handwritten manifests are the only handwritten dependency graph.
3. The ecosystem's resolver defines unit equality; the fabric records and caches
   it; it never manufactures equality for performance.
4. A capsule contains exactly the root's closure; unrelated projects are absent
   from resolution and from every derivation input.
5. Ledger entries, shards, capsule names, plan files and repository location are
   never unit derivation inputs.
6. A stale shard fails closed. Staleness is computed from **resolution inputs +
   target topology**, never from ordinary source contents.
7. Ambient host environment is not a compile input; exposed variables are
   declared contracts.
8. The real manifest is a compile input where the ecosystem says so.
9. Different resolved configuration (features/tags/flags/extras), target/ABI,
   role, profile, toolchain, native inputs, env, overlays or codegen result are
   different units.
10. Codegen/build scripts are ordinary build inputs, never evaluation data.
11. Resolver edges, compile overlays and Nix package edges are three graphs.
12. Packaging/runtime/module changes recompile zero units.
13. No feature union, no synthetic shared base, no peer-derived cache key.
14. A cache optimization may miss; it may never establish equivalence the
    ecosystem's resolver did not.
15. Mirrors are generated from canonical sources; a byte-identical provider swap
    introduces no repository-location input.
16. Toolchain, native policy, schema and backend version changes are global
    build-contract changes, versioned as such.
17. A unit the executor cannot faithfully express demotes its **capsule**, never
    the repository.
18. Production has no mutable cache-service dependency.

### 1.3 Generic unit descriptor

```text
Unit = {
  ecosystem, backendSchema,
  unitKind,                    # per ecosystem: rlib | goPackage | nodeTree | denoModule
                               #               | wheelInstall | cxxObject | binary | bundle
  identity: {
    name, version, sourceKind, sourceId,   # registry | git | path | url
    resolvedConfig,            # features / build tags / extras / defines / flags
    role,                      # host(builder) | target
    profile,
    targetTriple, abi,         # rustc triple; GOOS/GOARCH; node ABI; python tag; C++ ABI
    toolchain,                 # rustc/go/node/deno/python/cc, from the contract
    edition/spec/std,
  },
  depUnits, buildDepUnits, procMacroUnits,
  native,                      # selected build-side/target-side inputs
  compileEnv,                  # declared keys → values
  overlays,                    # declared compile-time provider inputs
  codegenResult,               # build script / generate output, when applicable
  sourceIdentity,              # canonical, location-independent
}
unitId = hash(canonical(Unit))          # the ledger key only
```

The Nix derivation remains the cache key. `unitId` is the ledger/selection key;
identical descriptors give identical derivations by construction.

**Native extension modules are a recurring pattern, modeled uniformly.** A Rust
`-sys` crate, a Node `node-gyp` addon, a Python C/C++/Cython/PyO3 extension and
a C++ object are all ordinary units whose identity carries an **ABI** (Rust
target triple, `NODE_MODULE_VERSION`, Python `SOABI`/`abi3` tag, C++ ABI). The
fabric has one mechanism for them; only the ABI field and the toolchain differ.

### 1.4 Three edge kinds, now across ecosystems

1. **Resolver edges** — the ecosystem's own dependency graph (cargo, go mod, npm
   lock, deno lock, pip lock, cmake/conan). Authoritative for units.
2. **Compile overlays** — non-resolver artifacts that are compile-time inputs: a
   built frontend injected into a Tauri app, generated protobuf/Thrift code,
   wasm output, codegen from another ecosystem.
3. **Nix package edges (`nixDeps`)** — assembled package/runtime/module
   dependencies: a Node check needing a Go binary, a service module needing a
   Rust executable.

Keeping these separate is what lets a Node→Rust or Python→Go edge be expressed
without corrupting either ecosystem's resolver graph.

### 1.5 Capability tiers and modes (the soundness mechanism)

Each package declares (or the adapter infers) a capability tier:

| tier            | meaning                                                                                                     | mode                                    |
| --------------- | ----------------------------------------------------------------------------------------------------------- | --------------------------------------- |
| **A — exact**   | The resolver can be captured exactly and hermetically (Rust, Go; Deno/Node/Python from a lock).             | `unit`                                  |
| **B — partial** | Capture needs tool introspection or is conditional (C++ File API; Python sdists; Node postinstall natives). | `unit` where expressible, else `native` |
| **C — opaque**  | No faithful unit capture (ad-hoc Makefiles, system-linked builds).                                          | `native` (one sandboxed native build)   |

Mode resolution is per capsule and fail-closed:

```text
mode(capsule) = policy.override
             else "legacy" if capsule ∈ legacyRegistry
             else "unit"   if every unit is in a proven class and all contracts are declared
             else "native"
```

`native` mode builds the project with its own tool in one derivation (from a
dummy/prepared source where possible) and inherits it for the real build — the
"correct but capsule-local reuse" fallback. A single unsupported unit demotes
one capsule.

### 1.6 Freshness (two digests, generalized)

```text
shard.stamp = {
  generatorRevision, resolverVersion, schemaVersion,
  resolutionDigest,   # root contract (resolver settings, shared dep table, patches/profiles),
                      # the lock, member manifest contents in the closure,
                      # selected provider manifests, (purpose, target, profile, mode)
  targetShapeDigest,  # per closure project: declared/auto target topology
                      #   (lib/main presence, bin/example/test/bench listings, build scripts)
}
```

`targetShapeDigest` hashes **topology, not contents** (e.g. Rust: `src/lib.rs`,
`src/main.rs`, `build.rs` presence and `src/bin/**` listing; Node: `scripts`
keys and `bin` fields; Go: package list; Python: console-scripts; C++: target
list). Ordinary source content edits do not stale a shard; adding/removing a
target or build script does. A stale shard throws with the regeneration command.

### 1.7 No-IFD argument

Evaluation reads only: `*.nix`; committed `ledger/**` and `plans/**`;
manifest/lock text via `builtins.readFile`/`fromTOML` on evaluator-visible
paths; target-topology listings via `builtins.readDir`; canonical
`builtins.path` sources; the declared contracts; external-source fetch specs.
Codegen, `OUT_DIR`, and provider derivations are ordinary build inputs. Release
gate: IFD disabled over all packages, checks, mirrors and provider-replacement
configurations from a cold evaluator.

### 1.8 Invalidation matrix (generic)

| change                                       | shard/ledger                          | units that move                                                                      |
| -------------------------------------------- | ------------------------------------- | ------------------------------------------------------------------------------------ |
| ordinary source file content                 | none                                  | that project's units + reverse chain                                                 |
| add/remove an ordinary module                | none                                  | that project's units + reverse chain                                                 |
| add/remove a target or build script          | topology digest → shard stale         | regenerate; new/changed target units + reverse chain                                 |
| metadata-only manifest edit                  | resolution digest → shard regenerates | that project's units may move (manifest is compile source); unrelated projects never |
| dependency add/remove/version                | affected shards                       | changed units + reverse chain                                                        |
| resolved config (features/tags/extras/flags) | affected shards                       | changed variants + reverse chain                                                     |
| local (in-repo) edge                         | both shards                           | required variant + project + chain                                                   |
| shared root table / lock                     | affected shards restamp               | only units whose resolved inputs changed; others keep identity                       |
| native policy for X                          | no re-resolution                      | X + link/runtime consumers                                                           |
| compile-env declaration for X                | no re-resolution                      | X + reverse chain                                                                    |
| compile overlay change                       | overlay provider id changes           | the consumer + reverse chain                                                         |
| toolchain / backend / schema                 | global contract change                | all affected units (versioned)                                                       |
| target / ABI                                 | that target's shards                  | that target's units; host units shared                                               |
| packaging / `nixDeps` / module / wrapper     | none                                  | zero units                                                                           |
| byte-identical mirror                        | none                                  | none                                                                                 |

**Shard regeneration ≠ recompilation.** A shard can be rewritten while every
unit derivation stays identical.

### 1.9 Mirroring and replacement (generic)

The mirror unit is the **package** (`P`): canonical source closure + contract +
lock + the referenced ledger subset + `P`'s shards + the declared contracts +
`nix/package.nix` + a canonical flake shim pinned to the fabric flake. `nixDeps`
become mirror inputs (or are materialized). Gates: `mirror-fresh` (regenerate +
byte diff), `mirror-parity` (mirror package drv == in-repo drv),
`mirror-standalone` (no monorepo root). Providers are exported per project and
overridable by a flake input; equal pins ⇒ equal derivations.

---

## 2. Ecosystem adapters

Each adapter supplies: declarations, a **resolver/producer**, the **unit kind**,
an **executor**, identity fields, native/ABI/toolchain contracts, cross model,
determinism tier, fallback mode, and mirror notes.

### 2.1 Rust (reference implementation)

- **Declaration/lock:** `Cargo.toml` + `Cargo.lock`; workspace contract
  (resolver, `[workspace.dependencies]`, `[profile]`, `[patch]`).
- **Producer:** cargo's own unit capture (`--message-format=json` artifact
  messages, or nightly `--unit-graph`); fallback `cargo metadata` projection.
  Must preserve the resolver-v2/v3 host/target feature split.
- **Unit:** (crate, resolved features, target/kind, role host|target, profile).
- **Executor:** `rustc` per unit (or a pinned `buildRustCrate`-style backend).
- **Native:** `-sys` crates via `(crate, targetTriple)` policy; `build.rs` as a
  build unit; proc macros as host units; declared compile env (`option_env!`).
- **Toolchain:** a **per-capsule toolchain contract** (see
  `.agents/docs/notes/tooling/rust-foundation-main-handoff-2026-10-12.md`):
  provider (`nixpkgs-rustc` default; `oxalica`/`fenix` for exact pins;
  `pinned-nixpkgs`; `rustup`), an optional `rust-toolchain.toml`, extra
  `targets`, components. The toolchain is an identity input, so `craneLib`
  becomes **`craneLibFor
  toolchain`** rather than one global.
- **Cross:** `--target <triple>`, target std + linker; host units shared across
  targets.
- **Tier A. Fallback:** `cargo` mode; `legacy` = current crane path.

### 2.2 Go

- **Declaration/lock:** `go.mod` (+ `go.work`) + `go.sum`; minimal version
  selection (MVS) is the resolver.
- **Producer:** `go list -json -deps -test ./...` with the pinned toolchain and
  `GOFLAGS`; captures module graph, package list, build constraints, cgo, and
  embedded files. Offline from the module cache/vendor.
- **Unit:** (package import path, module version, build tags, `GOOS/GOARCH`,
  `CGO_ENABLED`, toolchain/flags). Compiled packages are the units (Go compiles
  packages, not crates).
- **Executor:** `go build`/`go compile` per package; `go vet`/`go test` as
  purposes; `go generate` as codegen units.
- **Native:** cgo needs a C compiler and target libs → declare via native
  policy; pure Go needs none.
- **Cross:** `GOOS/GOARCH` are trivially first-class for pure Go; cgo cross
  needs a cross cc. Host (tool) units shared.
- **Tier A. Fallback:** `native` (`go build` once, module cache prebuilt).

### 2.3 Node

- **Declaration/lock:** `package.json` + `package-lock.json`/`pnpm-lock.yaml`/
  `yarn.lock`; workspaces.
- **Producer:** read the lock and the platform to compute the exact install tree
  (npm/pnpm resolution is deterministic from the lock: peer auto-install rules,
  `optionalDependencies` with `os`/`cpu` filters, deduplication). Optionally
  cross-check with `npm ls --json`/`pnpm list`.
- **Unit:** (package, version, prod|dev, platform triple `os/cpu/libc`, Node ABI
  for native addons). Pure-JS units are **content-addressed file trees** (no
  compilation) — cheap and trivially cached; native addons are compiled units.
- **Executor:** materialize the resolved tree (copy/link from a per-package
  store); build native addons with `node-gyp`/`prebuild-install`; bundling
  (`esbuild`/`vite`/`webpack`) is a separate unit/overlay.
- **Native:** `postinstall` scripts are the hazard — they can run arbitrary code
  and fetch at build time. Policy: default `--ignore-scripts`, with a declared
  allowlist whose scripts become build units; anything else demotes to `native`.
- **Native addons (shared with the Deno adapter):** a `node-gyp`/prebuild addon
  is a **native build unit** with a declared native policy (C/C++ toolchain,
  `make`, Python for gyp, Node headers) and an ABI identity of
  `(runtime, NODE_MODULE_VERSION, platform)`. Prebuilt binaries
  (prebuild-install / prebuildify / node-pre-gyp, or platform-filtered
  `optionalDependencies`) are tier-A file-tree units; building from source is
  tier B and, if headers/`python`/network are undeclared, tier C (`native`). A
  different Node ABI or platform is a different unit.
- **Cross/platform:** the lock's platform-conditional deps make the triple part
  of unit identity; a lock install is per-platform.
- **Tier A (locked, scripts-off) / B (postinstall natives). Fallback:** `native`
  (`npm ci` once in a sandbox with a fixed registry/snapshot).

### 2.4 Deno

Deno has **two resolution modes**, and both are lock-driven (tier A):

- **`npm:` specifier mode (default):** npm deps resolve from `deno.lock` into
  Deno's own cache (`DENO_DIR`); there is no `node_modules`.
- **`node_modules` mode:** `nodeModulesDir` (`true`, or
  `"auto"`/`"manual"`/`"none"` in Deno 2) with `package.json`/workspaces and
  `deno install` (Deno 2 supports a `package.json` + `deno.lock` npm flow). The
  Deno adapter **delegates npm resolution and tree materialization to the Node
  adapter**, so the same lock semantics, platform/`os`/`cpu` filtering, and ABI
  field apply and the units dedup against Node projects.

- **Declaration/lock:** `deno.json`/`deno.jsonc` + import map + `deno.lock`;
  imports are URLs (`https:`, `jsr:`, `npm:`); `package.json` when
  `node_modules` mode is on.
- **Producer:** `deno info --json` / `deno vendor` for the module graph and
  integrity, plus the Node adapter's lock resolution for the npm part; the
  producer records the graph and the exact remote artifacts (URL + integrity).
- **Unit:** (module specifier, integrity, import-map scope) for deno modules;
  npm package trees (via the Node adapter) for `node_modules`. Units are
  content-addressed verified files (no compilation; TS is handled by
  Deno/esbuild).
- **Executor:** materialize the vendored graph (`DENO_DIR`) and/or the npm tree;
  bundling (`esbuild`) is a unit; `deno compile` produces a binary unit;
  `deno task` is a dev path.
- **Native addons — a runtime capability, not just a build:** Deno's Node
  compatibility generally **does not load Node-ABI `.node` addons**, so building
  one does not make it runnable in Deno (verify against the current Deno
  release; this is a moving target; WASM alternatives sometimes work). The Deno
  adapter therefore records `runtimeSupportsNativeAddons = false` (currently),
  and a Deno capsule whose closure requires a native addon **demotes to the Node
  ecosystem**, requires a **WASM alternative**, or **fails closed** with a clear
  message — it never silently produces a Deno build that cannot load its
  dependency. The addon's _compilation_ (when needed) is the normal native build
  unit from §2.3 with its ABI identity.
- **Cross:** `deno compile` targets are explicit; otherwise the module graph is
  platform-independent, but the npm part is per-platform (as in Node).
- **Tier A (pure JS/TS); B when a native addon must be built (Node ecosystem,
  declared native policy); C (`native`) otherwise. Fallback:** `native`
  (`deno cache`/`deno vendor`/npm install once).

### 2.5 Python

- **Declaration/lock:** `pyproject.toml` (+ `uv.lock`/`poetry.lock`) or hashed
  requirements; PEP 517/518 build backends.
- **Producer:** `uv`/`poetry`/`pip` resolution from the lock → exact
  distribution set; the **interpreter** (CPython version/build, PyPy,
  free-threaded) and the **platform tag** are part of the request. Capture wheel
  metadata (RECORD, entry points, dependencies).
- **Interpreter and extension ABI are identity fields.** Python "C/C++ modules"
  come in distinct ABI flavours, and each is a different unit:
  - **pure Python** (`py3-none-any`) — file tree;
  - **stable-ABI `abi3`** (`cp3x-abi3-<platform>`) — shareable across 3.x ≥ the
    tag floor;
  - **versioned CPython ABI** (`cp312-cp312-<platform>`, `SOABI`) — locked to
    one interpreter minor; a new interpreter is a new unit;
  - **PyPy** and **free-threaded** (`cp313t`) — distinct ABIs;
  - the platform tag (`manylinux_2_28`, `musllinux`, `macosx_*`, `win_amd64`).
- **Unit — two kinds** (as for Node/Deno natives):
  - **wheel install** — unpack a verified
    `(distribution, version, ABI tag, platform tag, extras)` wheel into a prefix
    (pure file tree; hermetic; tier A);
  - **sdist build** — a PEP 517 build in an isolated environment that compiles
    an **extension module** and/or runs codegen (tier B, or `native` when the
    policy is undeclared). It decomposes into ordinary fabric units:
    - **codegen units** — Cython (`.pyx`→C), `cffi` (ABI/API mode), protobuf
      codegen;
    - **native units** — C, **C++** (composes with the C++ adapter), **Rust**
      (PyO3/maturin, composes with the Rust adapter), Fortran;
    - each consumes declared inputs: Python headers, a C/C++/Rust toolchain,
      system libs (native policy), and the vendored/pinned
      `[build-system]
      requires` (PEP 518) instead of fetching them.
- **Executor:** wheel unpack; sdist build via the declared backend driving the
  codegen + native units, producing a wheel the downstream install unit consumes
  (`OUT_DIR`-style); `venv`/site assembly for the package.
- **Native:** C/C++/Rust extensions need headers/libs and a compiler via the
  native policy, keyed by `(distribution, platform tag)`; `auditwheel`/
  `delocate` are packaging steps, not units.
- **Cross:** installing prebuilt wheels is fine when the target tag exists (pin
  it); **building** C/C++ extensions for a non-host platform needs a cross
  toolchain + target headers (or emulation, `cibuildwheel`-style), so it stays
  off the fast path and falls back to `native` per target.
- **Tier A (wheels) / B (sdists with a declared policy) / C (`native`).
  Fallback:** `native` (`uv sync`/`pip install` in a sandbox).
- **Determinism caveat:** an sdist build is the least hermetic unit in the
  fabric (build-dependency fetch, compiler/header availability,
  non-deterministic artifacts). Policy: `--only-binary=:all:` where allowed;
  otherwise vendor and pin build requirements, declare the native policy, and
  set `SOURCE_DATE_EPOCH`.

### 2.6 C++ (and mixed C/C++)

- **Declaration/lock:** `CMakeLists.txt`/`meson.build` (+ `conanfile`/
  `vcpkg.json` where a package manager is used). There is **no universal C++
  lock** — this is the weakest ecosystem.
- **Producer:** tool introspection — CMake **File API** (targets, sources,
  compile commands), `compile_commands.json`, Meson **introspection**
  (`meson introspect`), plus Conan/vcpkg locks when present. Without a package
  manager, the "lock" is the declared native toolchain + system inputs.
- **Unit:** (target, compiler+version, ABI (`libstdc++`/`libc++`, C++ standard),
  flags/defines, static|shared, dep units). Objects/libraries are units;
  header-only libs are content-addressed file trees.
- **Executor:** `cc`/`c++` per translation unit (or CMake/Ninja/Meson driving
  them), then link.
- **Native/ABI:** ABI is a first-class identity field; system libraries via
  pkg-config/native policy; toolchain file for cross.
- **Cross:** a cross toolchain file + target sysroot; ABI per target.
- **Tier B (introspectable CMake/Meson + locked deps) / C (ad-hoc/system).
  Fallback:** `native` (one CMake/Ninja build in a sandbox with the declared
  toolchain and system inputs).
- **Honest limit:** without a package manager, C++ unit identity is only as good
  as the declared toolchain/native policy; treat most C++ packages as tier B/C.

### 2.7 Adapter summary

| ecosystem | resolver                  | lock                  | unit                   | executor         | tier | fallback |
| --------- | ------------------------- | --------------------- | ---------------------- | ---------------- | ---- | -------- |
| Rust      | cargo                     | Cargo.lock            | rlib/proc-macro/bin    | rustc            | A    | `cargo`  |
| Go        | go mod (MVS)              | go.sum                | package archive        | go build         | A    | `native` |
| Node      | npm/pnpm/yarn             | npm/pnpm/yarn lock    | file tree (+addon)     | copy / node-gyp  | A/B  | `native` |
| Deno      | deno (+npm via Node)      | deno.lock             | verified module / npm  | vendor / esbuild | A/B  | `native` |
| Python    | uv/poetry/pip             | uv/poetry/hashed reqs | wheel install (+sdist) | unpack / PEP 517 | A/B  | `native` |
| C++       | CMake/Meson(+Conan/vcpkg) | File API / conan lock | object/library         | cc/cxx           | B/C  | `native` |

---

## 3. Cross-ecosystem composition

The three edge kinds make cross-ecosystem builds first-class:

- **Frontend into a desktop app:** Node/Deno build →
  `compileOverlays.frontend-dist` consumed by a Rust (Tauri) unit; the overlay
  provider id makes it a normal compile input.
- **WASM into a web app:** Rust `wasm32` units → wasm-bindgen/binaryen adapter →
  an overlay for a Node/Deno site unit.
- **Proto/Thrift codegen:** a generator unit (any ecosystem) → generated sources
  as an overlay for Rust/Go/Python/C++ units.
- **Runtime/assembly edges:** a Node service check that needs a Go binary, a
  NixOS module that needs a Rust executable — `nixDeps`, not resolver edges.

Each cross edge is declared in the package policy (`compileOverlays`, `nixDeps`)
and never enters an ecosystem's resolver graph.

---

## 4. Repository integration

```text
build-fabric/                 # one flake, consumed by reference
  flake.nix
  lib/
    core/                     # contract, capsule, source, ledger, shard, unit, providers, mirrors, modes
    adapters/{rust,go,node,deno,python,cpp}/
    cross.nix  native.nix  compile-env.nix  checks.nix  package.nix
  bin/{fabric-plan,fabric-mirror}
```

Per package:

```text
pkgs/<area>/<name>/
  <manifest(s)>               # Cargo.toml | go.mod | package.json | deno.json
                              # | pyproject.toml | CMakeLists.txt
  src/…
  nix/package.nix             # policy: ecosystem, overlays, nixDeps, native,
                              # packaging, checks, adapter, meta
```

Generated, committed:

```text
build/ledger/<unitId>.json                              # per-unit descriptors
build/plans/<capsule>/<purpose>.<target>.<profile>.json # shards
build/native-registry.nix  build/compile-env.nix        # declared contracts
build/mirrors/…                                          # generated mirror trees
```

- **Author API:** a directory with a manifest (+ `nix/package.nix` only for
  non-resolver concerns) is a package. No `deps = [...]`, no `cargoLock`, no
  `projectDir`.
- **Consumption:** `packages.<system>.<name>`, `apps`, `checks`, `devShells`,
  `nixosModules`, `overlays/pkgs.nix`, plus
  `lib.<system>.fabric.{ledger,shard,
  providers}` for introspection. A single
  repo-level knob set: default mode, and per-capsule mode overrides.
- **Naming:** _purpose_ (`build|test|lint|doc|example`) is a plan axis; _mode_
  (`unit|native|legacy`) is a capsule property. _Ecosystem_ is a package
  property.

---

## 5. Soundness analysis

### 5.1 Why one fabric is sound

- Every ecosystem factors as **declaration → resolver → resolved units → ledger
  → executor → assembly**. The Rust unit-DAG is the reference instance; the
  others are substitutions of resolver/executor/identity fields.
- The core contracts (unit descriptor, shard digests, three edge kinds, modes,
  provider/mirror, no-IFD) are **ecosystem-agnostic**; ecosystem specifics live
  only in adapters.
- Cross-ecosystem composition is a first-class edge kind, not a special case.
- Fail-closed capability tiers mean a weak ecosystem degrades a capsule, not the
  design.

### 5.2 Where soundness is conditional

| ecosystem | soundness condition                                                                                                                                                                     |
| --------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Rust      | Producer must capture cargo's host/target feature split exactly.                                                                                                                        |
| Go        | cgo/native inputs must be declared; pure Go is clean.                                                                                                                                   |
| Node      | Resolution is deterministic from the lock **only** with a fixed registry snapshot and `--ignore-scripts` (or an allowlist); platform-conditional deps make the triple part of identity. |
| Deno      | Remote import integrity must be pinned in `deno.lock`; vendoring must be hermetic.                                                                                                      |
| Python    | Sound for wheels; **sdists** are non-hermetic (build deps, network, C/Rust tools) — pin + vendor or fall back.                                                                          |
| C++       | No universal lock; sound only with a package manager (Conan/vcpkg) or a declared toolchain + native policy; otherwise tier C (`native`).                                                |

### 5.3 The three hard problems

1. **Capture fidelity per ecosystem.** The producer must record the ecosystem's
   own resolution, not reimplement it. Rust/Go have machine-readable unit
   output; Node/Python/Deno are lock-driven and easy; C++ needs introspection.
2. **Non-hermetic build steps.** Node `postinstall`, Python sdists, C++ system
   linking, arbitrary codegen. Mitigation: allowlist + declared contracts +
   `native` mode.
3. **Scale.** ~24 projects × N ecosystems × purposes × targets ⇒ a large but
   content-addressed ledger; eval must be lazy per shard, and the ledger read
   must not force unrelated units.

### 5.4 What does NOT generalize (and must stay per-adapter)

- The **unit kind** (rlib vs package archive vs file tree vs wheel vs object).
- The **resolver output format** and capture mechanism.
- The **native/ABI model** (target triple, GOOS/GOARCH, node ABI, wheel tag, C++
  ABI).
- The **executor** and **assembly** shape.
- The **determinism tier** and fallback tool.

### 5.5 Honest limits of the overarching design

- It is a **build-system rewrite** for every ecosystem, not just Rust: N
  producers, N executors, N native/ABI models, mirror generators per ecosystem.
- It replaces package-manager-installed workflows (npm/pip/go/cmake) with a
  plan/ledger workflow; developers must run a regeneration command on
  resolution-affecting edits.
- Cold-build compilation is per **distinct resolved unit** (≥ a union, ≤
  per-project); the win is locality, correctness and dedup, not fewer cold
  compiles than a union.
- Non-hermetic ecosystems (Python sdists, C++, Node scripts) remain conditional
  even with the fabric; the fabric makes the condition explicit and fail-closed.
- It is more machinery than the current repo needs (Pvl has Rust plus
  Node/Python/Go **examples** only).

---

## 6. Validation plan

Generic, per ecosystem:

- **V1 no-IFD** over all packages, checks, mirrors and provider replacements.
- **V2 plan freshness:** an ordinary source edit does not stale a shard; adding
  a target/build script does; a metadata-only manifest edit regenerates only the
  affected shards.
- **V3 source locality:** an ordinary source edit moves only that project's
  units + reverse chain.
- **V4 project locality (the decisive G4 test):** a member manifest edit moves
  only its units + chain; unrelated projects keep byte-identical derivations.
- **V5 cross-project/cross-capsule reuse:** a shared registry unit has one
  `unitId`/`drvPath` across capsules; a divergent config yields a distinct one.
- **V6 correct divergence:** deliberately different config/target/profile yields
  distinct units (no false sharing).
- **V7 env/native identity:** a declared env or native-policy change moves only
  X and its consumers.
- **V8 codegen / extension-module correctness** per ecosystem (build.rs,
  `go generate`, node-gyp, Cython/cffi, PEP 517 builds, CMake generated
  sources): a native extension builds and imports under the declared
  interpreter/runtime; an `abi3`/prebuilt artifact is shareable across versions,
  a versioned one is locked.
- **V9 producer fidelity vs the native tool** (go/no-go): captured units match
  the ecosystem's own resolved graph (packages, versions, config, roles, edges).
- **V10 purpose parity:** test/lint/doc purposes without opaque recompute.
- **V11 target/ABI:** per-ecosystem cross/target case; host units shared.
- **V12 mirror equality** per ecosystem (leaf, path-dependent, cross-ecosystem).
- **V13 replacement** (identical / source-changed / manifest-changed).
- **V14 mode gate:** an unsupported unit demotes exactly one capsule and that
  capsule still builds correctly.
- **V15 scale:** 24-project measurements per ecosystem before defaulting.

Go/no-go before adopting the fabric repo-wide: **V9 per ecosystem** (can the
producer faithfully capture the resolver?) and **V14** (does the fail-closed
demotion actually hold?). Everything else is optimization.

---

## 7. Rollout

1. **Core + Rust.** Generalize the Rust design into `core/` and re-express the
   Rust adapter on it; prove V1–V9 for Rust.
2. **Go + Deno.** Clean, capture-friendly; prove the generic core generalizes
   beyond Rust.
3. **Node.** Add the lock-driven adapter and the `postinstall` policy.
4. **Python.** Wheels first; sdists behind a policy with `native` fallback.
5. **C++.** Introspection-based; expect tier B/C and `native` for most packages.
6. **Cross-ecosystem overlays** (frontend→Tauri, wasm→web, proto codegen).
7. **Mirrors + adoption** per ecosystem.
8. **Default flip** per ecosystem after its scale measurement (V15).

Rollback is per capsule (`native`/`legacy`) and, authoritatively, by restoring
the baseline tree.

---

## 8. Risks

| risk                                                  | severity | mitigation                                                                             |
| ----------------------------------------------------- | -------- | -------------------------------------------------------------------------------------- |
| Producer fidelity per ecosystem                       | high     | capture the tool's own output; V9 go/no-go; `native` fallback                          |
| Non-hermetic builds (Python sdist, C++, Node scripts) | high     | allowlist + declared contracts; `native` mode                                          |
| Scale (ledger/units/eval)                             | medium   | lazy per-shard reads; content-addressed files; measure (V15)                           |
| Regeneration workflow friction                        | medium   | fail-closed shards with exact regeneration commands; per-unit files avoid conflicts    |
| C++ without a lock                                    | high     | require a package manager or accept tier C `native`                                    |
| Cross-ecosystem edge mis-modeling                     | medium   | three explicit edge kinds; never into a resolver graph                                 |
| Maintenance surface (N adapters)                      | high     | minimal core; adapters are small and independent; a weak adapter does not block others |

---

## 9. Conclusion

The Rust unit-DAG/Capsule/Ledger design **does generalize** into one overarching
build fabric for Rust, Go, Node, Deno, Python and C++. The generalization is
sound because the core is small and ecosystem-agnostic, and because the only
thing every ecosystem must provide — a resolver whose output can be captured —
exists for all six, though with very different quality.

The design should therefore be built **around the fabric**, with two conditions:

1. **Capability tiers and fail-closed modes are mandatory**, not optional. The
   fabric must never pretend that C++ has a Cargo-grade lock or that a Python
   sdist is hermetic.
2. **Adoption is per ecosystem and gated on producer fidelity (V9) and the mode
   gate (V14).** Rust and Go first (clean), Deno and Node next, Python
   (wheels-first), C++ last (expect `native` for much of it).

With those conditions, the fabric gives the repo one model, one ledger, one
mirroring/adoption story, cross-ecosystem composition, and unit-level locality
for every ecosystem — the strongest available design, honestly bounded.
