# Design M (MIRROR-L) — Final dual-mode Rust build-graph design

Status: **final design, implementation-ready** (council 2 engineering-manager
adjudication of E1 `L-KEEP`, E2 `FACET`, E3 `ECHO`). Supersedes the REWEAVE plan
(`.agents/docs/plans/design-f-build-graph-2026-09.md`) for G10/G11 purposes.
Builds on landed Design L
(`.agents/docs/plans/design-l-implementation-2026-09.md`) and adopts the
verified mechanics in `tmp/design-f2/research.md`.

Chosen architecture in one line: **keep landed L's composition-independent
`--offline -p m` semantics; add one explicit `base` artifact seam; build
component bases in the composition layer (not per member); generate
layout-preserving, byte-identical mirrors from the evaluated git revision; adopt
mirrors by name through `externalPackagesFor`; make equality a CI gate, not a
hope.**

---

## 0. Decision and one-paragraph summary

Adopt **E1 (L-KEEP) as the spine**, hardened by two narrow imports: E2's insight
that the dependency base must be **computed once in the composition layer and
injected** (not recomputed per member), and E3's insistence on a **single
explicit `base` argument with one normalized interface**. Reject E2's
package-definition rewrite (`definition.nix` planner) as the required author
API: it re-implements Cargo for a benefit (removing `projectDir`/`deps`) that
layout-preserving mirrors make unnecessary, and its ~280-line planner overshoots
the complexity budget while leaving unvalidated Cargo constructs. Reject E3's
"mirror-first / standalone flake is the unit of truth" thesis as branding: on
inspection it converges on the same mechanism (layout-preserving mirror,
`builtins.path` content addressing, injected base, generated mirror) while
adding a composition sketch that does not type-check and an in-repo flake-output
layer we do not need.

Concretely: keep
`pkgHelper.mkRustDerivation { pkgs; projectDir; deps;
internalDeps; … }` as the
author surface; add an optional `base ? null` and a composition-level
`basePolicy ∈ {union, component, legacy}`; build one canonical `componentBase`
per path-connected component **in the composition layer** from a generated
`pkgs/components.nix` registry; copy root manifests/lock and the component
member directories **byte-for-byte** into a mirror that preserves the
monorepo-relative layout, so `builtins.path` produces the same store path and
the component base and member layer are the **same derivations** in both modes;
expose the package flake's `lib.<system>.mkPackage { pkgs, base, pkgHelper }` as
the G11 injection seam; thread `externalPackagesFor` through
`flake.nix → root.nix → default.nix → packages.nix` and actually inject
`pkgHelper`/`defaultBase` into `callPackage`. Prove G10/G11 with three
fail-closed gates: `mirror-fresh` (bytes), `mirror-parity` (drvPath equality),
and `adoption-parity` (composed == in-repo). Roll back with
`basePolicy = legacy`.

The honest core tension is retained and exposed as a knob, not hidden: **union
base = maximum dedup but monorepo-keyed; component base = standalone- identical
but more compiles.** Under `union` the monorepo injects its base into the mirror
so adoption is byte-identical; a _purely standalone_ mirror is semantically
identical but a different base. Under `component` all three (standalone ==
composed == in-repo) are the same derivation hash.

---

## 1. Goals restated against this design

| goal                         | mechanism                                                                                                                                                                                                             |
| ---------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| No IFD                       | all eval-time reads are `builtins.readFile`/`fromTOML`/`readDir`/`pathExists`/`builtins.path` on evaluator-visible paths; the component base and canonical manifests are derivations referenced only inside the build |
| Correctness first            | L's `--offline -p m` resolution over a component-filtered source is untouched; no member manifest is rewritten to a union (REWEAVE dropped)                                                                           |
| Scale to 24 members          | sharing is per component; component bases are independent and hash-consed; the base strategy is a bounded, measured knob                                                                                              |
| Simple, intuitive API        | author keeps `mkRustDerivation { projectDir; deps; internalDeps; … }` plus optional `base`; consumer learns the package-flake contract once (`packages.<system>.<name>`, `lib.<system>.mkPackage`)                    |
| Low maintenance churn        | mirrors are generated from `git ls-files` at the evaluated rev; `projectDir`/`deps` are monorepo-relative constants that are _identical_ in the mirror (layout preserved), so there is no divergence to sync by hand  |
| Few compiles                 | one component base per component; union base available for monorepo-wide dedup; L's internal-dep `.prev` chaining                                                                                                     |
| `.rs` edits local            | base is dummy-sourced (manifests/lock/`.cargo` only); only the edited member and its dependents rebuild                                                                                                               |
| **G10 dual mode**            | layout-preserving generated mirrors + composition-layer component bases + vendored (computed) helper closure; standalone flake output contract                                                                        |
| **G11 seamless replacement** | `externalPackagesFor` name swap + `lib.mkPackage { pkgs, base, pkgHelper }` injection; in component mode the mirror drv is bit-identical to the in-repo drv                                                           |

---

## 2. Architecture and module boundaries

```text
                        pure eval (no IFD)                          build time
repo root Cargo.toml ─┐
member Cargo.toml   ──┼─▶ lib/flake/rust-components.nix  (generator/gate reader, pure)
Cargo.lock          ──┘        ├─ members, glob-free path-dep edges
                               └─ path-connected components C
                                        │
                                        ▼
                          pkgs/components.nix  (generated registry: id → memberDirs/packages)
                                        │
                                        ▼
lib/flake/component-bases.nix  ──▶  componentBase(C) per component   ┌────────────────────┐
(composition layer, pure eval)      buildDepsOnly(component source,   │ componentBase(C)   │
                                     dummy-src, --offline --workspace)│  dummySrc(C dirs)  │
                                        │                              │  root-members := C │
                                        ▼                              │  lock + vendor     │
lib/flake/packages.nix (+ externalPackagesFor)                         └─────────┬──────────┘
lib/flake/root.nix / default.nix                                                  │ cargoArtifacts
flake.nix (seam)                                                                  ▼
      │                                                  ┌───────────────────────────────┐
      │ inject pkgHelper + defaultBase + external map    │ memberLayer(m)  src=buildSrc(m)│
      ▼                                                  │   -p m; doInstallArtifacts     │
pkgs/<m>/default.nix ──▶ mkRustDerivation { base; … }     └───────────────────────────────┘
      │
      ▼
package flake contract ── externalPackagesFor ──▶ mirror lib.mkPackage { pkgs; base; pkgHelper }
```

New/changed modules:

| module                                               | kind                     | purpose                                                                                                                  | purity                    |
| ---------------------------------------------------- | ------------------------ | ------------------------------------------------------------------------------------------------------------------------ | ------------------------- |
| `lib/flake/rust-components.nix`                      | new, pure                | read `Cargo.toml` path-dep edges, compute path-connected components; used by the mirror generator and the freshness gate | pure; no `pkgs`, no crane |
| `pkgs/components.nix`                                | new, generated data      | component id → `{ memberDirs; packages; }`; committed and drift-checked                                                  | data                      |
| `pkgs/component-profiles.nix`                        | new, small hand-authored | optional per-component base `nativeBuildInputs`/`buildInputs` profile (function of `pkgs`); empty by default             | data                      |
| `lib/flake/component-bases.nix`                      | new, composition layer   | build one canonical `componentBase` per component from the registry + lock + vendor                                      | emits derivations         |
| `lib/flake/pkg-helper.nix`                           | modified                 | add `base`, factor `cargoWorkspaceMembersPrePatch`, add passthru, clean `removeAttrs`                                    | mixed (unchanged shape)   |
| `lib/flake/packages.nix`                             | modified                 | accept/forward `pkgHelper`, `externalPackagesFor`, `componentBaseFor`; resolve by manifest name                          | emits derivations         |
| `lib/flake/root.nix`, `lib/flake/default.nix`        | modified                 | thread the new defaulted seam                                                                                            | mixed                     |
| `scripts/rust-mirror.sh`                             | new                      | generate mirrors from `git ls-files`; `--check`/`--publish`                                                              | tooling                   |
| `lib/flake/rust-components.nix` tests + mirror gates | new                      | `mirror-fresh`, `mirror-parity`, `adoption-parity`                                                                       | eval/build                |

**Hard rule:** the component base is computed **exactly once, in the composition
layer**, and injected. `mkRustDerivation` never computes a component base from a
single member. This is the fix for E1 P1-2/P1-3 and E3 P2-4.

---

## 3. Author and consumption API

### 3.1 Author API (unchanged shape, one optional argument)

`pkgs/<m>/default.nix` stays a function of `pkgs`/`pkgHelper` and calls
`mkRustDerivation`. The only new supported field is `base`:

```nix
{ pkgs ? import <nixpkgs> {},
  pkgHelper ? import ../../../lib/flake/pkg-helper.nix,
  # G11 injection seam; null => composition/legacy policy applies
  base ? null }:
pkgHelper.mkRustDerivation {
  pkgs = pkgs;
  inherit base;
  pname = "abird-host-agent";
  version = "0.1.0";
  projectDir = "pkgs/tools/abird-host-agent";   # monorepo-relative; identical in a mirror
  buildAttrs.doCheck = false;
  nativeCheckInputs = [ pkgs.rsync ];
  enableDevShell = true;
  meta = { description = "…"; mainProgram = "abird-host-agent";
           platforms = pkgs.lib.platforms.linux; };
}
```

`projectDir`/`deps`/`internalDeps` stay explicit because they are **stable under
layout preservation** and therefore are not "kept in sync by hand" between the
monorepo and a mirror. They are the natural, legible description of a package;
deriving them (E2) was never required for G10 and is deferred as an optional
convenience (§12, M6). The multi-crate edge stays exactly as landed:

```nix
deps = [ "pkgs/tools/abird-host-agent" ];
internalDeps = pkgs.lib.optional (abirdHostAgent != null) abirdHostAgent;
```

`mkRustDerivation` keeps the compatibility argument `abirdHostAgent ? null`
through the manifest `args` path (do **not** rename it to `internalPackages`;
that is what breaks E3 P1-5's bit-for-bit legacy rollback).

### 3.2 `mkRustDerivation` delta

```nix
pkgHelper.mkRustDerivation {
  pkgs; projectDir; deps ? []; internalDeps ? [];
  # --- new, all optional; defaults reproduce landed L exactly ---
  base ? null,            # derivation | null: externally supplied dependency artifacts
  baseLabel ? null,       # diagnostics only; not an input
  component ? null,       # composition metadata (memberDirs); diagnostics + gate
  ...
}
```

Semantics of the dependency prefix:

```nix
prefixNode =
  if base != null then base
  else if !workspaceMode then packageCargoArtifacts      # legacy per-package (L)
  else sharedDepsBase;                                   # L union base
```

- There is **no** `baseStrategy` string inside `mkRustDerivation` that silently
  flips the repo. Policy lives in the composition layer (which passes `base` or
  nothing). `legacy` is `useWorkspaceDeps = false`, exactly as landed.
- `base` **must be removed from `buildArgs`**: add `"base"`, `"baseLabel"`,
  `"component"` to the existing `removeAttrs` list (fixes E1 P2-8 / E3 B1). An
  eval-time `assert base == null || isDerivation base` makes misuse loud.
- `passthru` additions: `baseStrategy` (resolved: `"injected"|"union"|"local"`),
  `depsBase` (`prefixNode`), `componentDirs` (`null` unless known),
  `mirrorUnit`.

### 3.3 Consumption API (what a consumer learns once)

A package flake must expose, per system:

```nix
packages.<system>."<pname>"     # standalone derivation
packages.<system>.default       # primary member
checks.<system>."<pname>".{build,fmt,lint,test}
apps.<system>."<pname>"         # when meta.mainProgram
devShells.<system>.default
formatter.<system>
nixosModules                    # when the package declares one
lib.<system>.mkPackage          # { pkgs, base ? null, pkgHelper ? <vendored> } -> drv   ← G11 seam
lib.<system>.depsBase           # the component base derivation
lib.<system>.component          # { id; memberDirs; packages; }                          ← gate metadata
```

`mkPackage` accepts the consumer's `pkgs` **and** `pkgHelper` so the monorepo
can compose with its own builder and eliminate helper drift; when omitted it
uses the mirror's vendored helper. A standalone build is
`mkPackage { pkgs = mirrorPkgs;
base = depsBase; }` — literally the same call
the monorepo makes with `base =
<injected>`.

---

## 4. Derivation planner

There are two pure-eval planners; **neither computes features, versions, or a
feature fixpoint** (the E2 P1-2 trap is rejected).

### 4.1 `lib/flake/rust-components.nix` (generator/gate reader, ~120 lines)

- Input: evaluator-visible `src` path. Reads root `Cargo.toml`
  (`builtins.fromTOML . builtins.readFile`) and each member's `Cargo.toml`.
- `members`: root `[workspace].members`; simple globs expanded with
  `builtins.readDir` + `builtins.match`. A non-expandable glob returns
  `components = null` (degrade to L with a `lib.warn`), never throws.
- Edge `a → b` when `a` has a `path` dependency (any of `[dependencies]`,
  `[dev-dependencies]`, `[build-dependencies]`, `[target.<cfg>.*]`) resolving
  lexically to member `b`. Undirected adjacency; connected components.
- Output `components`: deterministic, sorted
  `[ { key; memberDirs; packages; } ]`.
  `key = builtins.hashString "sha256" (concatStringsSep "\n" (sort memberDirs))`
  (fixes E1 NOTE-12).
- Used **only** by `scripts/rust-mirror.sh` and the freshness/parity gate. It is
  not on the build path; a bug in it fails a gate, it never mis-builds silently.

### 4.2 `lib/flake/component-bases.nix` (composition layer)

For each entry of `pkgs/components.nix`:

```nix
componentBase = pkgs.craneLib.buildDepsOnly {
  dummySrc = pkgs.craneLib.mkDummySrc {
    src = mkWorkspaceSourcePath pkgs {
      inherit src;
      selectedDirs = component.memberDirs;          # layout-preserving
      name = "cargo-workspace-source";              # fingerprint invariant
    };
  };
  pname = "abird-rust-${component.key}";
  version = "0.1.0";
  cargoExtraArgs = "--offline --workspace";          # NOT --locked (see §4.3)
  prePatch = cargoWorkspaceMembersPrePatch {
    members = builtins.sort builtins.lessThan component.memberDirs;
  };
  inherit (resolvedCraneCargoLockAttrs) cargoLockContents;
  cargoVendorDir = craneCargoVendorDir;
  nativeBuildInputs = profile.nativeBuildInputs or [];
  buildInputs = profile.buildInputs or [];
  env = { CARGO_NET_OFFLINE = "true"; };
};
```

- `cargoWorkspaceMembersPrePatch` is the factored awk (the non-`projectDir`
  variant of the existing `cargoWorkspacePrePatch`); the member path keeps using
  the existing `cargoWorkspacePrePatch { projectDir; deps; }`.
- The base is dependency-only; it carries the **component profile** from
  `pkgs/component-profiles.nix` (empty by default). This is the
  composition-layer profile fix for E1 P1-2 / E3 P2-4: no member computes it, so
  no two members of a component can disagree, and a component needing a native
  tool to compile a dependency declares it in one place.
- Host filtering: the composition passes only **host-available** member dirs
  (from `meta.platforms`), so a Darwin-only member never enters a Linux
  `--workspace` (fixes E1 §9 / E3 P2-5).
- Hash-consing: all inputs are canonical (sorted dirs, resolved lock/vendor), so
  Nix produces one base drv per component.

### 4.3 `--locked` decision

- **Member builds keep `--offline` (no `--locked`), exactly as landed L.**
- **Component base uses `--offline --workspace` (no `--locked`).** E2 P1-4/B2
  proved `--locked` fails once the member list is pruned/rewritten; the E3
  "locktest2" claim is not relied on.
- The version pin is the vendor directory:
  `vendorCargoDeps { cargoLockContents }` hashes the exact lock text, so an
  identical lock ⇒ identical vendor ⇒ exact crate versions. The member source
  and the base source copy the lock verbatim, so no re-resolution can move a
  version. This is the honest replacement for `--locked` and is gated by
  `cargo metadata --offline` (V4).
- If a future cargo demands `--locked`, we regenerate a component-filtered lock
  — explicitly future work, not a current assumption.

### 4.4 Dependency prefix and internal chaining

`dependencyArtifacts` is unchanged from L: no internal deps → base/injected
base; one → the dependency's `passthru.memberLayer`; two or more →
`mkCargoArtifactsJoin`. `sharedDepsBase` is set to `null` when `base != null`
(fixes E1 NOTE-13 / E3 P2-1: no unused, mirror-broken base derivation is built
or advertised).

---

## 5. The base seam and `basePolicy`: equality matrix

### 5.1 Where policy lives

| layer                                                         | decision                                                                                                          |
| ------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `mkRustDerivation`                                            | `base != null` wins; else workspace mode uses the union base; else legacy. No repo-wide flip.                     |
| monorepo composition (`packages.nix` + `component-bases.nix`) | `basePolicy` per component: `union` (default; inject nothing → L base) or `component` (inject `componentBase(C)`) |
| mirror package flake                                          | always builds with its own `componentBase`; `mkPackage { base }` accepts an injected base                         |
| adoption                                                      | `externalPackagesFor` may pass the monorepo base into the mirror's `mkPackage`                                    |

### 5.2 Equality matrix (what each mode guarantees)

| mode        | base used in monorepo                            | standalone == composed                                              | composed == in-repo                                  | cache sharing                                                 | relative cost                                                    |
| ----------- | ------------------------------------------------ | ------------------------------------------------------------------- | ---------------------------------------------------- | ------------------------------------------------------------- | ---------------------------------------------------------------- |
| `union`     | L `sharedDepsBase`                               | **no** (standalone uses its own component base; semantically equal) | **yes**, if the base is injected through `mkPackage` | exact when adopted with injection                             | 367 externals (measured, 5 members)                              |
| `component` | `componentBase(C)`                               | **yes** (`drvPath` equality)                                        | **yes** (`drvPath` equality)                         | exact by hash-consing; publishing either cache satisfies both | ~2.05× at 5 members _for component bases_; re-measure at N (§13) |
| `legacy`    | per-package `packageCargoArtifacts` (L rollback) | yes (L)                                                             | yes                                                  | partial (L residual)                                          | L baseline                                                       |

- **"Semantically equal" has a precise meaning here:** the member still resolves
  `R(m)` from its own manifests, lock, toolchain, and `-p m` selection; the base
  is a memoization of compiled units. Cargo rebuilds any unit whose fingerprint
  (features/profile/toolchain/source) differs; it never substitutes a mismatched
  unit. Therefore the linked artifact is a function of `R(m)`, not of the base.
  This is verified empirically by `cargo metadata -e features --offline` diff,
  not by theorem (V7).
- **The default is `union`** so landing the seam is a zero-regression change.
  The monorepo flips components to `component` one at a time as their mirrors
  land. Mirrors are always `component`.
- **No over-claim:** `component` is the only mode whose _standalone_ build is a
  cache-sharing peer of the monorepo. `union` gives seamless _replacement_ but
  not standalone cache identity.

---

## 6. G10 — mirror workflow, generation, drift gates

### 6.1 Unit

A mirror is one **path-connected component**: the smallest set of crates
buildable alone. Today `{abird-host-agent, abird-host-manager}` is one unit
(`manager → agent` path dep); `hello-rust`, `nats-http-bridge`,
`nats-wrecking-ball` are singletons. A "manager alone" mirror is impossible
without vendoring agent or rewriting the path dep.

### 6.2 Layout (layout-preserving) and file set

```text
<mirror>/
  flake.nix                 # generated, thin
  flake.lock                # generated: pins nixpkgs/crane + the monorepo lock rev
  Cargo.toml                # BYTE copy of the monorepo root manifest
  Cargo.lock                # BYTE copy of the monorepo lock
  .cargo/                   # BYTE copy if present (fingerprint-relevant)
  .gitignore                # BYTE copy (mkWorkspaceSourcePath filter reads it)
  treefmt.toml              # BYTE copy (fmt checks)
  lib/flake/pkg-helper.nix  # vendored, byte-identical (Tier 1)
  lib/flake/**              # computed transitive import closure only (see §8)
  pkgs/components.nix       # generated, component-filtered
  pkgs/manifest.nix         # generated, component-filtered
  pkgs/<component dirs>/    # BYTE copy at the same monorepo-relative paths (tracked files only)
```

Layout preservation is the load-bearing choice: `projectDir` stays
`"pkgs/tools/abird-host-agent"`, sibling `path` deps (`../abird-host-agent`)
keep resolving, and `builtins.path` yields the same store path as the monorepo.

### 6.3 Generator (`scripts/rust-mirror.sh`)

Source of truth = **the evaluated git revision**, never the worktree:

1. Resolve `REV` (default `HEAD`) and read bytes with `git show "$REV:path"` /
   `git archive "$REV" -- <paths>`.
2. Run `rust-components.nix` (via `nix eval`) to get components + member dirs.
3. Copy, only for tracked files at `REV`: root `Cargo.toml`, `Cargo.lock`,
   `.cargo/**`, `.gitignore`, `treefmt.toml`, and every file under each member
   dir. **Forbid untracked/non-gitignored bytes under a selected dir** (E1 P1-4
   / E3 P2-2: `builtins.path` selects the whole dir, so an extra byte changes
   the store path). CI runs `git status --porcelain` over member dirs and fails
   on untracked files.
4. Vendor the computed `lib/flake` import closure (Tier 1) or emit the pinned
   `libflake` input line (Tier 2).
5. Emit `pkgs/components.nix` and a component-filtered `pkgs/manifest.nix`
   (preserving `args` wiring).
6. Emit `flake.nix` from a checked-in template; the template builds `pkgs` with
   the **crane overlay** (`crane.mkLib prev`) and `follows` nixpkgs/crane, so
   the standalone build uses the L crane path — not the current
   `rustPlatform.buildRustPackage` fallback (fixes E1 P1-5).
7. `--check`: regenerate into `$TMPDIR` and `diff -r` against the committed
   mirror. Nonzero on any drift. `--publish`: a separate network step.

Determinism: sorted output, `git show` bytes, no timestamps, no worktree reads.

### 6.4 Drift and parity gates (fail-closed in CI)

- `checks.mirror-fresh`: regenerate every mirror and diff. Catches hand edits,
  stale locks, stale vendored helper, stale registry. This is the mirror
  analogue of `union-fresh` and the highest-value control.
- `checks.mirror-parity`: for every component package `m`,
  `mirror.lib.${system}.mkPackage { pkgs = monorepoPkgs; base = null; }.drvPath ==
  monorepo.packages.${system}.${m}.drvPath`
  **in component mode**, and `== monorepo.packages.<m>.drvPath` with the
  monorepo base injected in union mode. The union-mode gate must build
  `abird-host-manager` **and** agent, with the injected base threaded to both
  (fixes E1 P1-7): the mirror's `mkPackage` takes `pkgHelper` and `base` and
  applies them to the whole component.
- `checks.mirror-standalone`: build `mirror.packages.<system>.<name>` with the
  mirror's _own_ `pkgs` and compare drvPath to the monorepo member after the
  component is flipped. This closes the "standalone technically exists but isn't
  the same package" hole (E1 P1-5).
- `--option allow-import-from-derivation false` is asserted for the monorepo and
  every mirror.

### 6.5 Non-Nix `cargo` in a mirror

The verbatim root manifest lists members that do not exist in the mirror, so a
raw `cargo build` fails until the member list is rewritten. Decision: **G10 is
scoped to Nix builds**, and the generated mirror `devShell` applies the same
member-list rewrite as a shell hook so `cargo`/`rust-analyzer` work for
developers. A canonical component-filtered root manifest (so raw `cargo` works
without a hook) is deferred to M6 (§12) because it changes the source bytes and
must be generated identically in both modes to preserve drv equality (E2 §4).

### 6.6 Migrating the 13 existing child `flake.nix` wrappers

They are **not** G10 mirrors today (they import `stack/package.nix` by relative
path, rely on `../..`, and get no crane overlay). Plan: replace each with either
(a) a tracked `mirrors/<id>/` generated tree, or (b) a generated wrapper that
uses the same template. The tracked wrappers currently live under member dirs,
so they are part of `builtins.path`; deleting/moving them changes member source
hashes. Do this before the first parity baseline and update the drift baseline
in the same change (E3 P2-3).

---

## 7. G11 — adoption, injection, package-flake contract

### 7.1 The seam (must actually reach the build)

Thread a defaulted `externalPackagesFor ? _system: {}`, `pkgHelper ? <import>`,
and `defaultBase ? null` through:

```text
flake.nix → lib/flake/root.nix → lib/flake/default.nix → withPkgs → packages.nix
```

`packages.nix` resolves each manifest name and **injects `pkgHelper`** into
`callPackage` (fixes E1 BLOCKER-1 / E3 B1):

```nix
canonicalPackages = builtins.mapAttrs (name: entry:
  if externalPackages ? ${name}
  then
    let e = externalPackages.${name}; in
    if builtins.isFunction e then e { inherit pkgs pkgHelper; base = componentBaseFor name; }
    else e
  else
    pkgs.callPackage entry.path (
      { inherit pkgHelper; }
      // (if entry ? args then entry.args canonicalPackages else {})
      // (if componentBaseFor name != null then { base = componentBaseFor name; } else {})
    )
) validatedEntries;
```

- Replacement is **by manifest name**, so
  `entry.args packages: { abirdHostAgent =
  packages.abird-host-agent; }`
  automatically receives the external agent, and manager's `internalDeps`
  inherits the external agent's `memberLayer` (the passthru contract already
  required by the existing guard).
- A failed external evaluates to `null`/throws; `isAvailablePackage` already
  drops it and the in-repo package remains, with a `lib.warn` (graceful
  degradation).
- `--override-input <mirror> path:/abs/tmp` gives a one-line temporary swap with
  no lock write (`--no-write-lock-file`). Relative `path:` inputs are forbidden
  (research §1.2); use absolute `path:`, `git+…?dir=`, or `file:`. Any in-repo
  `path:` input must be git-tracked.

### 7.2 Adoption modes (exactly two; E2 Mode C is dropped)

| mode           | mechanism                                                                                                                                                                                     | equality                                | cache                     |
| -------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------- | ------------------------- |
| **derivation** | `externalPackagesFor` returns the mirror's `packages.<system>.default` (or a function returning it)                                                                                           | semantic; drv may differ                | none unless base injected |
| **injected**   | function form `{ pkgs, pkgHelper, base }: mirror.lib.<system>.mkPackage { inherit pkgs pkgHelper base; }` with `base = componentBaseFor name` (component mode) or the union base (union mode) | composed `drvPath` == in-repo `drvPath` | exact                     |

Mode C ("declaration adoption") is rejected: it never builds the mirror's source
and is not "use the mirrored package in place of the in-repo package" (E2 P1-3).

### 7.3 `lib.mkPackage` contract

```nix
lib.<system>.mkPackage = { pkgs, base ? null, pkgHelper ? <vendored> }:
  <the same mkRustDerivation call the in-repo default.nix makes, with the
   supplied pkgHelper/base>
```

- **Same call, no fork** (E3 I1). Standalone is
  `mkPackage { pkgs = mirrorPkgs;
  base = depsBase; }`; composition is
  `mkPackage { pkgs = monorepoPkgs;
  pkgHelper = monorepoHelper; base = <injected>; }`.
- `mkPackage` returns a derivation whose `passthru` exposes at least
  `memberLayer`, `projectDir`, `depsBase`, `checks`, `fmt`, `lint-fix`, `pkgOps`
  — the subset the existing `internalDeps` guard and downstream checks rely on.
- `assert base == null || pkgs.lib.isDerivation base` at eval.

### 7.4 Exact drv-identity conditions (for the gates)

`mirror(m).drvPath == member(m).drvPath` iff all hold:

1. identical source bytes under the selected dirs + root
   `Cargo.toml`/`Cargo.lock`
   - `.cargo` + `.gitignore` (layout-preserving, tracked-only, evaluated rev);
2. same `prePatch` text (same sorted member dirs) and same `cargoExtraArgs`;
3. same `prefixNode` (same injected base drv, or the same canonical component
   base);
4. same `pkgs` (nixpkgs + `craneLib`); the parity gate forces this by passing
   `monorepoPkgs`, and production mirrors align via `follows`;
5. same `nativeBuildInputs`/`buildInputs`/`nativeCheckInputs` and `buildAttrs`;
6. same vendor derivation (identical lock text ⇒ identical `vendorCargoDeps`).

Conditions 1, 2, 5 are guaranteed by generation + the shared helper; 3, 4, 6 are
gated.

---

## 8. `lib/flake` extraction plan

### 8.1 Tier 1 (default): vendored, computed import closure

The mirror vendors `lib/flake` files **at the same relative paths**, but only
the transitive relative-import closure the component needs — not the whole
directory. This is why the "26 `../..` sites" (root.nix, tests, accounts,
data/secrets, …) are out of scope: they are not in the closure.

- Rust-only components (`agent`, `manager`, `hello-rust`, `nats-*` where they do
  not use `srv`): the closure is `lib/flake/pkg-helper.nix` (which has **no
  sibling imports**) plus `treefmt.toml`. Because the layout is preserved,
  `pkg-helper`'s `../..` (`repoRoot`, default `src`, `treefmt.toml`) resolves to
  the mirror root. **No parameterization is required for Tier 1.**
- `srv`-using components (`hello-rust`, `nats-http-bridge`, `nats-wrecking-ball`
  call `srv.mkModule`/`mkIdentity`): `default.nix` imports `stack/package.nix`,
  which imports `pkg-helper.nix` + `service-module.nix`; `stack/lib.nix`
  additionally pulls `secrets.nix`, `units.nix`, and `../../services/nginx/*`.
  Two honest options, chosen per component:
  1. **vendor the exact closure** (generator computes it by scanning `import`
     statements and copying those files), including `service-module.nix` and its
     escapes; or
  2. **generate a `srv` stub** in the component registry and pass it via
     `entry.args` (`{ srv = stub; }`) so `default.nix` does not import
     `stack/package.nix`; `nixosModules` is then supplied by the monorepo
     composition, not the mirror. Default to (1) when `nixosModules` must work
     standalone, (2) otherwise. Either way the manifest records which, and
     `mirror-fresh` checks the closure. This reconciles E1 §5.3/P1-6 and E1
     §11.3 / E3 P2-2.

### 8.2 Tier 2 (optional, later): isolated library flake

Only if `lib/flake` must become a real standalone flake:

1. Parameterize the four `pkg-helper.nix` escapes: `repoRoot ? null`,
   `treefmtConfig ? null`, and required `src` at the two default sites. Keep the
   defaults so Tier 1 is untouched.
2. Split the service stack out of the Rust core (`stack/package.nix` = rust
   core + service stack; `lib/flake-service` owns `service-module.nix`).
3. `lib/flake/flake.nix` inputs `nixpkgs`, `crane`, `flake-utils`; outputs
   `lib.pkgHelper`, `lib.rust`, `overlays.default`; no `../../` escapes, no
   `pkgs/manifest.nix` at module scope (composition injected).
4. Mirrors pin `libflake` with `follows` nixpkgs/crane; **skew is gated on the
   exact rev/hash, not a hand-maintained integer** (fixes E3 P1-6). The
   composition passes its own `pkgHelper`, so composition is skew-immune; only a
   standalone mirror is exposed, and the gate compares revs.

Version skew between vendored copies is caught by `mirror-fresh` (byte diff).

---

## 9. Dev-dependencies, checks, native inputs

- **Dev-deps:** component bases use `buildDepsOnly` (`doCheck = true`), which
  runs `cargo check --all-targets`, `cargo build`, and `cargo test --no-run`, so
  normal, build/proc-macro, dev/test, bench, and example units are primed.
  Member `checks.test` inherits `memberLayer` and reuses them.
- **Native build inputs:** the **component profile**
  (`pkgs/component-profiles.nix`) is an input to the component base and is
  computed once per component in the composition layer; member-specific compile
  inputs stay on the member layer. `nativeCheckInputs` stay on the member/check
  layer. This resolves the per-member profile impossibility (E1 P1-2) and the E3
  P2-4 wording gap.
- **Checks:** `fmt` (no artifacts), `lint` (`cargoClippy` on `memberLayer`),
  `test` (`cargoTest` on `memberLayer`), all `-p <m>` and `--offline`.
- **Closure isolation:** the deployed `buildPackage` inherits `memberLayer` and
  does **not** export artifacts, so the artifact archive never enters the
  runtime closure (L invariant preserved).
- **`CARGO_NET_OFFLINE=true`** on all crane attrs so install-time
  `cargo metadata` works in the sandbox without a lock rewrite.

---

## 10. Platform gating and native inputs

- `availableAttrs` already drops packages unavailable on the host.
- The composition filters component member dirs to the **host-available** subset
  before building the component base, so a Darwin-only member cannot break a
  Linux `--workspace` (E3 P2-5; Design L P1-A).
- Bases are keyed by `(component, host)`; a cross-host component gets one base
  per host. The planner preserves `[target.<cfg>.*]` tables verbatim.
- A cross-host path-dep component is flagged by the mirror generator as a G10
  hazard (it cannot share one base).

---

## 11. Diagnostics and degradation

- `passthru` on every package: `baseStrategy` (`"injected"|"union"|"local"`),
  `depsBase`, `componentDirs`, `mirrorUnit`, plus the existing `memberLayer`,
  `sharedDepsBase`, `projectDir`.
- `flake.rustMirrors` output: components, member dirs, packages, chosen policy,
  base drv, mirror file manifest, and the vendored closure — for `nix eval`.
- `lib.warn` (never throw) on: non-expandable glob; manifest parse failure; a
  component spanning platforms; a missing/empty profile; `base` of the wrong
  type; an `externalPackagesFor` entry that fails to evaluate; helper-closure
  mismatch.
- Degradation always falls toward L: `useWorkspaceDeps = false` (legacy
  per-package) is the rollback shape, bit-for-bit. The generator/gates are
  additive; removing `externalPackagesFor` and stopping mirror generation
  restores the pre-M behavior.

---

## 12. Dep-churn and `.rs`-locality (honest)

| change                                    | component mode                                                                                                                                                    | union mode (default monorepo)                                            |
| ----------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| `.rs` **content** in `m`                  | `buildSrc(m)` + `memberLayer(m)` + dependents; every component base byte-stable                                                                                   | same                                                                     |
| `.rs` **add/remove**                      | expected same, but `mkDummySrc` launders manifest trees; **S7 must verify** no base change (L review recorded a caveat for `src/lib.rs`,`src/main.rs`,`src/bin/`) | same                                                                     |
| member `Cargo.toml` external edit         | that component's base + its members                                                                                                                               | union base changes ⇒ all external units recompile repo-wide (L behavior) |
| member `Cargo.toml` path/internal edit    | component membership may change; that component's base/members                                                                                                    | same, within the component                                               |
| `Cargo.lock` / `[workspace.dependencies]` | **global** (bytes are copied into every component base)                                                                                                           | global (correct)                                                         |
| new member                                | global (root manifest + lock)                                                                                                                                     | global                                                                   |

- **Global root-manifest/lock churn is the honest v1 cost.** It is L's existing
  behavior made per-component. The optional **canonical component manifest**
  (M6) localizes it: generate a component-filtered root manifest in _both_
  monorepo and mirror with the same pure function, so drv equality is preserved
  while churn localizes. It is deferred because it changes source bytes and must
  be proven.
- **Whole-lock churn across mirrors:** every mirror carries the full lock, so a
  lock bump invalidates every mirror until regenerated. Regeneration is one
  command; `mirror-fresh` makes it fail-closed. A component-filtered lock is
  future work.
- We do **not** claim exactly-once for arbitrary feature requests. In a
  multi-crate component, a dependent that requests different features on a
  sibling can recompile it in its own layer (bounded, in-repo, documented).
  Component mode cannot remove this; the union base can mask it at the cost of
  mirror identity.

---

## 13. Staged migration

| stage    | change                                                                                                                                                         | behavior / risk                                              |
| -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------ |
| **M0**   | add `base`/passthru + `removeAttrs`; factor `cargoWorkspaceMembersPrePatch`; add `lib.warn` diagnostics                                                        | none; L unchanged; `base=null` always                        |
| **M1**   | land `rust-components.nix` + generated `pkgs/components.nix` + `component-bases.nix` (built, unused) + `component-profiles.nix`                                | pure eval + unused derivations; validated by eval tests      |
| **M2**   | thread `externalPackagesFor` + `pkgHelper`/`defaultBase` through the composition; add the package-flake contract; wire `mirrorUnit`/`componentDirs` passthru   | no build change; seam is inert (`externalPackagesFor` empty) |
| **M3**   | generator + first mirror `{agent,manager}`; `mirror-fresh`/`mirror-parity`/`mirror-standalone`; flip that component to `component`; delete/migrate its wrapper | first real build; medium risk; gates catch drift             |
| **M4**   | migrate remaining Rust components + singletons; add gates to CI; key gates on changed components                                                               | low                                                          |
| **M5**   | generalize the mirror template + contract to non-Rust `pkgs/...` helper families (`mkGo*`, `mkNode*`, `mkPython*`, `mkTrunkProject`, `mkWeb*`, `mkAggregate`)  | each family gets its own `lib.mkPackage`; G10 scope closed   |
| **M6**   | optional: canonical component manifest (churn localization), `lib/flake` Tier-2 extraction, component clustering                                               | medium; must preserve drv equality                           |
| rollback | `basePolicy = legacy`, drop `externalPackagesFor`, stop generating mirrors                                                                                     | restores landed L bit-for-bit                                |

No package `default.nix` is required to change for M0–M4 except the M3 wrapper
migration. The `abirdHostAgent` compatibility argument is retained so the legacy
manifest path stays bit-for-bit.

---

## 14. Validation spikes and gates

### 14.1 Spikes (must pass before M3 flips a component)

- **S1** `rust-components.nix` on the real repo yields exactly
  `{{agent,manager},{hello-rust},{nats-http-bridge},{nats-wrecking-ball}}`;
  deterministic; malformed manifest degrades with a warning.
- **S2 (source identity)** `mkWorkspaceSourcePath` from the monorepo vs a
  `git archive` mirror produce the same store path (E1 E-A reproduced).
- **S3 (component base identity)** `componentBase` drv is identical from
  monorepo and mirror with the same `pkgs` (E1 E-B reproduced).
- **S4 (GATE-M component)**
  `mirror.mkPackage { pkgs; base = null }.drvPath ==
  member.drvPath`.
- **S5 (GATE-M union-injected)**
  `mirror.mkPackage { pkgs; base = depsBase;
  pkgHelper = monorepoHelper }.drvPath == member.drvPath`,
  building **manager** (not only agent) and threading the base to both.
- **S6** `externalPackagesFor` swap of agent; build/test manager; its
  `internalDeps` picks up the external layer.
- **S7** `.rs` content edit leaves every base drv byte-stable; `.rs` add/remove
  base-stability **verified or documented as an exception**.
- **S8** `mirror-fresh` fails on a one-byte edit and on an untracked extra file.
- **S9** `nix flake check` on the mirror with the component's
  `nativeCheckInputs` (`rsync`, `jq`, …).
- **S10** flake mechanics already verified in `tmp/design-f2/flake-exp/`
  (`path:`, `?dir=`, `flake=false`, `follows`, `--override-input`; relative
  `path:` and untracked inputs forbidden).
- **S11 (eval cost)** `nix eval .#packages` for in-repo import vs `mirrors`
  `flake=false` at 5 and 24 components; record the curve.

### 14.2 Standard gates

- **V1 no IFD:** `nix eval --option allow-import-from-derivation false` for the
  monorepo and every mirror; no unguarded `readFile`/`readDir`/`pathExists`.
- **V2 lock fidelity:** `cargo metadata --offline` inside a member build shows
  no used-version change; vendor hashes lock text.
- **V3 `.rs` locality:** content edit changes only the edited member +
  dependents; base byte-stable.
- **V4 no leak:** deployed package closure contains no artifact archive.
- **V5 component-base count:** exactly one base drv per component; all members
  report it; `sharedDepsBase` is `null` when `base` is injected.
- **V6 mirror parity:** `mirror-fresh` + `mirror-parity` + `mirror-standalone`.
- **V7 semantic equality (union):** `cargo metadata -e features --offline -p m`
  identical standalone vs composed; `pname`/bin names/lock identical.
- **V8 host filtering:** no host-unavailable member enters a `--workspace` base.
- **V9 eval tests:** components deterministic; every member in exactly one
  component; no component split; degrade-without-throw.
- **V10 all existing checks** (`nix flake check`, `pkgOps`, formatter) green.
- **V11 legacy rollback:** `basePolicy = legacy` reproduces landed L drv paths
  bit-for-bit.

---

## 15. Complexity and maintenance budget

| piece                                                                        | est. lines | kind                   |
| ---------------------------------------------------------------------------- | ---------- | ---------------------- |
| `lib/flake/rust-components.nix`                                              | ~120       | pure eval              |
| `lib/flake/component-bases.nix`                                              | ~90        | composition            |
| `pkg-helper.nix` delta (`base`, factor awk, passthru, warnings, removeAttrs) | ~110       | emitter                |
| `packages.nix`/`root.nix`/`default.nix` seam                                 | ~60        | composition            |
| generated `pkgs/components.nix` + `pkgs/component-profiles.nix`              | ~40        | data                   |
| mirror `flake.nix` template + package-flake contract                         | ~120       | generated              |
| `scripts/rust-mirror.sh` + closure scanner                                   | ~220       | tooling                |
| eval tests + gates                                                           | ~150       | tests                  |
| **total**                                                                    | **~910**   | no new derivation kind |

Maintenance rules:

- The planners never resolve features/versions; if a change would need semver or
  a feature fixpoint, degrade to `legacy` and warn.
- All lists sorted/deduped so hash-consing is stable.
- The public author API grows only optional arguments; defaults reproduce L.
- If `rust-components.nix` exceeds ~200 lines, stop and degrade the affected
  component to a hand-declared registry entry.

---

## 16. Risks and explicit non-guarantees

1. **Layout-preserving mirrors are not "normal" repos.** Raw `cargo` needs the
   devShell member rewrite; a clean-root mirror cannot be drv-identical. This is
   the price of exact cache sharing.
2. **`union` is not standalone-reproducible.** Only injected adoption is
   byte-identical; a purely standalone union build is not.
3. **Component mode is a real compile cost.** ~2.05× at 5 members; at 24
   components the worst case approaches "one external compile per component".
   Re-measure (S11) and gate the component default on a measured budget.
4. **The single lock couples mirror freshness to the monorepo.** Generation is
   mandated; `mirror-fresh` catches omission only at CI time.
5. **`[workspace.dependencies]` inheritance forces the whole root manifest into
   every mirror** (v1); the canonical manifest is the localizer and is deferred.
6. **Component membership is manifest-derived.** A typo can merge/split a
   component; the reader warns and the parity gate catches drift, but the graph
   is only as good as the manifests.
7. **`lib/flake` Tier 2 is not free.** The four escapes and the service-stack
   split are prerequisites; Tier 1 vendoring is the recommended steady state.
8. **Non-Rust families** get the contract but not the deep component-base
   engineering until M5; G10 for them is "generated standalone flake", with the
   same parity discipline but family-specific base policy.
9. **Eval cost at 24 members** is bounded only empirically; `mirrors`
   (`flake=false`) is the default to avoid per-mirror flake evaluation.
10. **Untracked files under member dirs** change `builtins.path`; CI forbids
    them.
11. **W10 transitive feature residual** is reduced, not eliminated, by component
    scoping; it cannot change a member binary under `-p m` semantics, and it is
    reported as a cache-efficiency diagnostic.

---

## 17. Decision log

### 17.1 Architecture adjudication

| candidate                                                         | verdict                                             | reason                                                                                                                                                                                                       |
| ----------------------------------------------------------------- | --------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **E1 L-KEEP**                                                     | **spine (accepted, hardened)**                      | smallest delta on landed L; keeps composition-independent `-p m`; the only candidate whose mirror is bit-identical by construction; all blockers are seam fixes, not architecture                            |
| **E2 FACET**                                                      | **partially accepted; definition rewrite rejected** | its composition-layer/base-at-composition insight and canonical-manifest idea are good; its `definition.nix` planner re-implements Cargo and overshoots the budget for a benefit layout preservation removes |
| **E3 ECHO**                                                       | **converged, not adopted as spine**                 | mirror-first is branding; its layout/base/policy insights are already E1's; its in-repo flake-output composition does not type-check and adds a layer we do not need                                         |
| **REWEAVE**                                                       | **rejected**                                        | its union member-manifest rewrite makes a member's effective features a function of monorepo peers, disqualifying it for G10/G11                                                                             |
| **Plan A/aggregate, Plan B/signature-clustering** (prior council) | rejected as spine                                   | A has no real manifest/lock; B is the measured ~2.05× regression and cannot guarantee mirror identity; both are superseded                                                                                   |

### 17.2 Accepted/rejected blockers (all three critiques)

**E1 critique**

| id                                                      | verdict     | resolution                                                                                                  |
| ------------------------------------------------------- | ----------- | ----------------------------------------------------------------------------------------------------------- |
| BLOCKER-1: `base` never reaches `mkRustDerivation`      | **accept**  | `packages.nix` explicitly injects `pkgHelper`/`defaultBase`/`base` into `callPackage`; gate proves the seam |
| P1-2: component profile unimplementable from one member | **accept**  | compute the profile once in `pkgs/component-profiles.nix`; base built in composition layer                  |
| P1-3: default `component` silently flips the repo       | **accept**  | no in-helper default flip; monorepo stays `union`; composition selects per component                        |
| P1-4: generator source-of-truth                         | **accept**  | generate from `git ls-files`/`git archive` at the evaluated rev; forbid untracked bytes                     |
| P1-5: standalone mirror must wire crane                 | **accept**  | generated flake uses `crane.mkLib` + `follows`; `mirror-standalone` gate                                    |
| P1-6: `srv` members cannot use a Rust-only bypass       | **accept**  | computed vendored closure or generated `srv` stub, chosen per component                                     |
| P1-7: union gate must thread base to siblings           | **accept**  | mirror `mkPackage` applies `base`/`pkgHelper` to the whole component; gate builds manager                   |
| P2-8: new args leak into `buildArgs`                    | **accept**  | add `base`/`baseLabel`/`component` to `removeAttrs`                                                         |
| P2-9: cost is a 5-member extrapolation                  | **accept**  | S11 re-measures; worst-case bound stated                                                                    |
| P2-10: mirror root members point at absent dirs         | **partial** | scope G10 to Nix builds + devShell rewrite; canonical manifest deferred                                     |
| P2-11: Tier-2 `lib` input ignored                       | **accept**  | thread `pkgHelper` (same as BLOCKER-1)                                                                      |
| NOTE-12: `componentKey` undefined                       | **accept**  | key = sha256 of sorted member dirs; tested in S1                                                            |
| NOTE-13: `sharedDepsBase` computed needlessly           | **accept**  | `null` when `base != null`                                                                                  |
| NOTE-14: `componentBase` source name                    | **accept**  | kept `cargo-workspace-source`; load-bearing                                                                 |

**E2 critique**

| id                                                                      | verdict                       | resolution                                                                                       |
| ----------------------------------------------------------------------- | ----------------------------- | ------------------------------------------------------------------------------------------------ |
| B1: layout contradictory / generator omits member sources               | **accept**                    | layout-preserving; generator emits all component member dirs                                     |
| B2: `--locked` fails on pruned workspace; S2 false                      | **accept**                    | base uses `--offline`; vendor pins versions; `cargo metadata` gate                               |
| P1-1: union injection re-monorepo-keys adoption; gate tests non-default | **accept**                    | equality matrix is explicit; union adoption is byte-identical, standalone only semantic; V7 gate |
| P1-2: planner re-implements Cargo, overshoots budget                    | **accept → planner rejected** | no `definition.nix` planner; `rust-components.nix` is a thin read-only reader                    |
| P1-3: Mode C incoherent                                                 | **accept**                    | Mode C dropped                                                                                   |
| P1-4: 24-member CI unbounded                                            | **accept**                    | gates key on changed components; sample/opt-in locally                                           |
| P2-1: whole-lock churn                                                  | **accept**                    | honest; canonical manifest localizer deferred                                                    |
| P2-2: extraction prerequisites understated                              | **accept**                    | computed closure + explicit Tier-2 prerequisites                                                 |
| P2-3: definition migration churn                                        | **accept**                    | avoided by keeping the author API                                                                |
| P2-4: filter env can diverge (`.gitignore`/`.cargo`)                    | **accept**                    | both copied byte-identically; drift gate                                                         |
| P2-5: native/platform keying unaddressed                                | **accept**                    | component profile + host subset + `(component, host)` key                                        |

**E3 critique**

| id                                               | verdict    | resolution                                                                     |
| ------------------------------------------------ | ---------- | ------------------------------------------------------------------------------ |
| B1: seam misnamed `cargoArtifactsBase` vs `base` | **accept** | public arg is `base`; eval assert; `removeAttrs`                               |
| B2: composition sketch does not type-check       | **accept** | use the `callPackage` seam; no in-repo flake-output composition; one interface |
| P1-1: G10 is Rust-only                           | **accept** | contract generalized per helper family in M5                                   |
| P1-2: `src` default removal                      | **accept** | keep defaults in Tier 1; parameterize only in Tier 2                           |
| P1-3: 26 `../..` sites understated               | **accept** | Tier 1 vendors only the computed closure; whole-dir extraction is Tier 2       |
| P1-4: `mirrors` input not optional               | **accept** | do not declare it by default; `--override-input` only when declared            |
| P1-5: `legacy` rollback broken by arg rename     | **accept** | keep `abirdHostAgent`; do not rename to `internalPackages`                     |
| P1-6: integer contract version too weak          | **accept** | gate on exact lib rev/hash                                                     |
| P1-7: unapplied imports                          | **accept** | definitions remain functions applied by `callPackage`/`mkPackage`              |
| P2-1: `sharedDepsBase` broken in mirror          | **accept** | `null` when base injected                                                      |
| P2-2: untracked files break source identity      | **accept** | generator copies tracked bytes; CI forbids untracked under member dirs         |
| P2-3: member wrappers in the source tree         | **accept** | migrate/delete wrappers before the baseline; refresh drift                     |
| P2-4: base is per-component, not per-member      | **accept** | base carries component profile; member inputs stay on the member layer         |
| P2-5: eval cost asserted                         | **accept** | S11 measures                                                                   |
| P2-6: `--locked` hand-wave                       | **accept** | `--offline` + vendor pin                                                       |
| P2-8: mirrors lock not pure                      | **accept** | mirrors pin the monorepo lock rev; no independent lock                         |

### 17.3 Prior-art decision

| prior art                                                | decision                                                                                                                                  |
| -------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| Design L                                                 | **retained as the semantic contract and rollback**                                                                                        |
| REWEAVE / Design F                                       | **rejected** for G10/G11; its `cargoWorkspaceMembersPrePatch` factoring and freshness idea are re-used, its union manifest rewrite is not |
| `union-fresh` gate                                       | **retained as a diagnostic** (V7), demoted from correctness backstop                                                                      |
| `external-source-units.md` convention                    | **adopted** as the generator/drift philosophy                                                                                             |
| `shared-test-areas.md` byte-identical discipline         | **adopted** for vendored `lib/flake`                                                                                                      |
| `package-project-boundaries.md` desired standalone shape | **target**, realized by the generated mirror contract                                                                                     |

---

## 18. What is guaranteed, and what is not

**Guaranteed (gated):**

- No IFD on the monorepo and every mirror.
- `.rs` content edits never invalidate a component base (S7).
- In `component` mode, `standalone == composed == in-repo` by `drvPath`
  (`mirror-parity`, `adoption-parity`, `mirror-standalone`).
- In `union` mode, `composed == in-repo` by `drvPath` when the monorepo base is
  injected; standalone is semantically equal (`cargo metadata` gate) but not a
  cache peer.
- Mirrors are generated from the evaluated rev and drift-checked; no hand-sync
  of `projectDir`/`deps`/lock.
- `basePolicy = legacy` reproduces landed L bit-for-bit.
- Every external unit compiles once per base; `.rs` locality preserved.

**Not guaranteed (honest):**

- Bit-identical binaries across _different_ bases (only semantic equality, gated
  by `cargo metadata`).
- Standalone cache identity in `union` mode.
- Component mode's compile cost being close to union's; it is ~2.05× at 5
  members and must be re-measured at 24.
- Raw `cargo` in a mirror without the devShell rewrite.
- Localized churn on `[workspace.dependencies]`/lock until the canonical
  manifest lands.
- Exactly-once for arbitrary feature requests within a multi-crate component.
- `lib/flake` as an isolated flake until the four escapes are parameterized and
  the service stack is split (Tier 2).

---

## 19. References

- `tmp/design-f2/research.md` — verified flake mechanics, sharing measurements,
  extraction escapes.
- `tmp/design-f2/plan-e1.md`, `critique-e1.md`; `plan-e2.md`, `critique-e2.md`;
  `plan-e3.md`, `critique-e3.md` — adjudicated inputs.
- `.agents/docs/notes/tooling/rust-build-graph-dual-mode-goals-2026-09.md` —
  G10/G11.
- `.agents/docs/plans/design-l-implementation-2026-09.md` — landed L mechanics.
- `.agents/docs/plans/design-f-build-graph-2026-09.md` — REWEAVE (rejected
  spine; `cargoWorkspaceMembersPrePatch` and freshness ideas reused).
- `.agents/docs/notes/tooling/rust-build-graph-review-2026-09.md` — L findings
  (P1-A host filter, P1-B diagnostics, P2-a compile-only layer).
- `.agents/docs/design-patterns/package-project-boundaries.md`,
  `shared-test-areas.md`, `external-source-units.md`.
- `lib/flake/pkg-helper.nix` — `mkWorkspaceSourcePath` (67),
  `mkCargoWorkspaceSource` (102), `rustWorkspaceMembers` (142),
  `mkRustWorkspaceSource` (167), `mkSharedRustDepsBase` (179),
  `mkCargoArtifactsJoin` (198), `cargoWorkspacePrePatch` (235),
  `mkRustDerivation` (2103), `memberLayer` (~2400).
- `lib/flake/packages.nix`, `root.nix`, `default.nix`, `stack/package.nix`,
  `pkgs/manifest.nix`, `flake.nix`.
