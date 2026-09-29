# Design L Implementation Plan (2026-09)

Concrete, staged implementation plan for **Design L** described in
`.agents/docs/plans/rust-workspace-build-graph-2026-09.md`. That document holds
the design rationale; this one holds the work items, exact anchors, pseudo-code,
risks, and validation.

> **Implementation notes (2026-09).** Corrections landed while implementing: (1)
> member builds keep the per-member source (`mkCargoWorkspaceSource`), not the
> whole-workspace source, so editing one member's `*.rs` only invalidates that
> member and its dependents; the whole-workspace source is used only to derive
> the shared base's `.rs`-independent dummy. (2) build artifacts live in a
> separate `memberLayer` (artifacts-only) that only build consumers reference,
> so the deployed package's runtime closure stays lean. (3) each `internalDeps`
> dependency's `passthru.projectDir` is auto-unioned into the member source. The
> source-filter scaffolding is shared via `mkWorkspaceSourcePath`. (4) The
> in-repo edge stays optional: the standalone child-flake build has no
> `abirdHostAgent`, so `internalDeps` is set with `pkgs.lib.optional` while
> `deps` always keeps the dependency directory; the misuse guard fires only for
> structural misuse, letting the rollback and glob-degraded shapes fall back to
> the legacy per-package path. (5) A dependency rolled back with
> `useWorkspaceDeps = false` exposes no `memberLayer`, so dependents drop it
> from the artifact chain and compile it from source (graceful, not a throw).

## Scope and outcome

After Design L:

- One **shared external-dependency base** (`depsBase`) derived from a
  whole-workspace dummy source, so every external crate and dev-dependency
  compiles once repo-wide, independent of `*.rs` content.
- One **member layer per workspace crate** with a per-member source, so an edit
  invalidates only the edited member and its in-repo dependents.
- **No IFD.**
- Per-package `default.nix` still calls
  `pkgHelper.mkRustDerivation { projectDir; ... }`; the API grows two optional
  args and keeps its existing shape.

## Invariants

1. **No IFD.** Every eval-time read is a plain file (`builtins.readFile`,
   `builtins.fromTOML`, `builtins.path` filter). Never `readFile`/`readDir` a
   derivation.
2. **Identity dedup.** Shared derivations (`source`, `dummySrc`, `depsBase`)
   must be built from identical canonical arguments in every call so Nix
   hash-conses them to one drv. Never thread per-package `buildAttrs` into them.
3. **Source-name match.** The dummy source used by `depsBase` and the real
   source used by member layers must both unpack to
   `/build/cargo-workspace-source`. `mkDummySrc` derives its output name from
   the input source basename, so the laundered source must be named
   `cargo-workspace-source`.
4. **One compile per crate.** Externals compile in `depsBase`; each member crate
   compiles in exactly one member layer; dependents inherit that layer's
   artifacts rather than recompiling it.
5. **Fallbacks preserved.** Non-crane platforms, `projectDir = null`
   (`hello-rust-isolated`, `nestedRustPackage`), and non-workspace projects keep
   the current per-package behavior.

## Target graph

```text
workspaceSource       builtins.path, name = "cargo-workspace-source"
└── dummySrc          mkDummySrc(workspaceSource)   # Cargo.toml/lock/.cargo only

depsBase              buildDepsOnly(dummySrc, --workspace)   # externals + dev-deps, once

perMemberSrc(m)       mkCargoWorkspaceSource([m] ++ resolvedDeps)   # real source, per member
memberLayer(m)        cargoBuild { src = perMemberSrc(m);
                                   cargoArtifacts = depsBase or memberLayer(internalDeps(m));
                                   -p m; doInstallCargoArtifacts = true }   # artifacts only

pkg(m)                buildPackage { src = perMemberSrc(m);
                                     cargoArtifacts = memberLayer(m);
                                     ...per-package attrs }   # deployed, no artifacts

checks(m)             cargoFmt / cargoClippy / cargoTest { cargoArtifacts = memberLayer(m) }
```

Dependency chain for the current repo (artifacts only; `pkg` inherits its
layer):

```text
depsBase ──▶ memberLayer(abird-host-agent) ──▶ memberLayer(abird-host-manager)
        └──▶ memberLayer(hello-rust)
        └──▶ memberLayer(nats-http-bridge)
        └──▶ memberLayer(nats-wrecking-ball)
```

`abird-host-manager` inherits `pkg(abird-host-agent)` through the `.prev` chain
it already carries, so no multi-parent join is needed.

## Work items

### W1 - Whole-workspace laundered source

`mkRustWorkspaceSource` (near `mkCargoWorkspaceSource`) reads the member list at
eval time and delegates to the shared `mkWorkspaceSourcePath` filter:

```nix
mkRustWorkspaceSource = pkgs: src:
  mkWorkspaceSourcePath pkgs {
    inherit src;
    selectedDirs = rustWorkspaceMembers src;   # root manifest members, glob-guarded
  };
```

- `rustWorkspaceMembers` reads the root manifest only behind
  `builtins.isPath
  src` (no IFD) and returns `[]` if any member is a glob,
  disabling sharing repo-wide rather than building a broken base.
- `mkWorkspaceSourcePath` keeps the root manifest, lockfile, `.cargo` config,
  and the selected member directories; `name ? "cargo-workspace-source"` is
  invariant-critical.
- The forbidden-directory assertion (`.git`/`target`/`dist`) lives only on the
  member source (`mkCargoWorkspaceSource`'s `runCommandLocal`); the
  whole-workspace path feeds `mkDummySrc`, which keeps only manifests/lock/
  `.cargo`, so no assertion is needed there.
- Must keep `.cargo/config.toml`, root `Cargo.toml`, root `Cargo.lock`.
- Member sources keep the `cargoWorkspacePrePatch` member-list rewrite; the
  whole-workspace source does not rewrite members.
- Name is load-bearing: `cargo-workspace-source`.

### W2 - Shared dependency base

Canonical, attrs-free base so every call dedups to one drv.

```nix
mkSharedRustDepsBase = pkgs: {
  source,            # W1 laundered path
  cargoLockContents,
  cargoVendorDir,
}: let
  craneLib = pkgs.craneLib;
in
  craneLib.buildDepsOnly {
    dummySrc = craneLib.mkDummySrc {src = source;};  # no `src`: avoids crane's ignored-src warning
    pname = "abird-rust-workspace";                   # buildDepsOnly appends `-deps`
    version = "0.1.0";
    cargoExtraArgs = "--offline --workspace";
    inherit cargoLockContents cargoVendorDir;
  };
```

- `--workspace` selects every member; the base is shared, so a future member
  that cannot build on a host would break the base for all members. If
  platform-gated members are added, switch to an explicit `-p` list (or
  `--workspace --exclude`). Glob members (`crates/*`) are not expanded by the
  member reader, which disables sharing repo-wide rather than building a broken
  base.
- `doCheck` stays crane's `true`, so `cargo test --no-run` caches dev-deps.
- `buildDepsOnly` sets `cargoArtifacts = null` internally; nothing to thread.

### W3 - Rewire `mkRustDerivation`

Key symbols in `lib/flake/pkg-helper.nix`: `buildSrc`, `craneDepsAttrs`,
`prefixNode`/`dependencyArtifacts`, `memberLayer`, `cargoArtifacts`, and
`build`. Prefer symbol references over line numbers (they drift).

Add parameters:

```nix
useWorkspaceDeps ? projectDir != null,   # escape hatch / rollback
internalDeps ? [],                       # in-repo member packages this crate links
```

Derive workspace mode and artifacts:

```nix
workspaceMode =
  useWorkspaceDeps && craneLib != null && projectDir != null
  && builtins.isPath src && isWorkspaceMember src projectDir;   # W1's member list

resolvedDeps = pkgs.lib.unique (deps ++ map (dep: dep.passthru.projectDir) internalDeps);

buildSrc =
  if projectDir == null then src
  else mkCargoWorkspaceSource pkgs { inherit src projectDir; deps = resolvedDeps; };

prefixNode = if !workspaceMode then packageCargoArtifacts else sharedDepsBase;
dependencyArtifacts =
  if internalDeps == [] then prefixNode
  else if builtins.length internalDeps == 1 then (builtins.head internalDeps).passthru.memberLayer
  else mkCargoArtifactsJoin pkgs { name = pname; deps = map (dep: dep.passthru.memberLayer) internalDeps; };

memberLayer =                       # artifacts-only, compiles the member exactly once
  craneLib.cargoBuild (craneCommonAttrs // {
    cargoArtifacts = dependencyArtifacts;
    doInstallCargoArtifacts = true;
  });

# Structural misuse only; the rollback and glob-degraded shapes fall through to
# the legacy path. Must be forced (`builtins.seq`), since `dependencyArtifacts`
# is only evaluated in workspace mode.
internalDepsGuard =
  if internalDeps == [] then null
  else if craneLib == null || projectDir == null || !(builtins.isPath src) then throw "internalDeps is unusable here"
  else null;

cargoArtifacts = if workspaceMode then memberLayer else builtins.seq internalDepsGuard packageCargoArtifacts;
```

- Member builds keep the per-member source and the member-list rewrite, so
  editing one member's `*.rs` invalidates only that member and its dependents.
  The whole-workspace `mkRustWorkspaceSource` (W1) is used only to derive the
  shared base's dummy source, which is `*.rs`-independent.
- `resolvedDeps` unions each `internalDeps` dependency's `passthru.projectDir`,
  so `deps` never has to be kept in sync by hand.
- `cargoArtifacts` in workspace mode = `memberLayer`; otherwise the current
  per-package `buildDepsOnly`.
- `sharedDepsBase` is the W2 value, computed from canonical inputs only.

### W4 - Separate the artifacts-only layer from the deployed package

Each member gets a `memberLayer` (`craneLib.cargoBuild`, artifacts-only) that
compiles the member once and publishes `$out/target.tar.zst`. The deployed
`buildPackage` inherits `memberLayer` (so it compiles nothing) and does **not**
publish artifacts, so the dependency archive never enters the deployed package's
runtime closure. Keep the existing `doCheck` (per-package `buildAttrs`).

### W5 - Checks inherit the member layer

`mkCraneCheckAttrs` threads the shared `cargoArtifacts` value (now
`memberLayer`) into `cargoClippy` / `cargoTest`. Keep
`doInstallCargoArtifacts = false` on checks. No change beyond W3.

### W6 - Wire the in-repo dependency edge

Pass the dependency's **package derivation** so the dependent inherits its exact
artifacts.

- `pkgs/manifest.nix`, `abird-host-manager` entry:

  ```nix
  abird-host-manager = {
    path = ./tools/abird-host-manager/default.nix;
    args = packages: { abirdHostAgent = packages.abird-host-agent; };
    rootApp = true;
  };
  ```

- `pkgs/tools/abird-host-manager/default.nix`:

  ```nix
  { pkgs ? import <nixpkgs> {}, pkgHelper ? ..., abirdHostAgent ? null }:
  pkgHelper.mkRustDerivation {
    pkgs = pkgs;
    pname = "abird-host-manager";
    projectDir = "pkgs/tools/abird-host-manager";
    # Always keep the dependency directory in the source; inherit its artifacts
    # only when the root composition supplies the package (standalone child-flake
    # builds have none).
    deps = ["pkgs/tools/abird-host-agent"];
    internalDeps = pkgs.lib.optional (abirdHostAgent != null) abirdHostAgent;
    ...
  }
  ```

- `mkRustDerivation` reads each `internalDeps` dependency's
  `passthru.projectDir` and unions it into the member source, so `deps` does not
  need manual syncing.
- Each `internalDeps` entry must be a package derivation exposing
  `passthru.projectDir` (provided by `mkRustDerivation`); a non-derivation or a
  missing pass-through fails loudly. Membership in `rustWorkspaceMembers` is the
  caller's responsibility (the current single edge satisfies it).
- The dependency package is optional so the standalone child-flake and
  `callPackage {}` paths still evaluate (they lose layered sharing, not
  correctness).

### W7 - Multi-parent join helper (only for >= 2 internal deps)

Not needed for the current repo; required when a member links two in-repo
crates, because crane chains a single `.prev` parent. Build a self-contained
full archive so ordering/`realpath` subtleties do not apply.

```nix
mkCargoArtifactsJoin = pkgs: { name, deps }: let
  craneLib = pkgs.craneLib;
in
  craneLib.mkCargoDerivation {
    pname = "${name}-cargo-artifacts";
    version = "0.1.0";
    src = null;
    cargoArtifacts = builtins.head deps;
    cargoVendorDir = null;
    doCheck = false;
    doInstallCargoArtifacts = true;
    doCompressAndInstallFullArchive = "1";
    buildPhaseCargoCommand = "";
    checkPhaseCargoCommand = "";
    preBuild = ''
      ${builtins.concatStringsSep "\n" (map (d: "inheritCargoArtifacts ${d}") (builtins.tail deps))}
    '';
  };
```

- `cargoArtifacts` (head) is auto-inherited in `postPatch`; the rest are
  inherited in `preBuild`; the post-install hook then tars the full target dir.
- Cost: one full archive per fan-in node. Acceptable for L; Design F removes it.

### W8 - Fix the `dummySrc` defect in the legacy crane entry points (landed)

The legacy (non-workspace) paths used to pass the real source as `dummySrc`, so
`useWorkspaceDeps = false` (the rollback) reinstated the source-invalidation
defect. This landed in the same series (see the decision note):

- `mkRustDerivation` legacy path: `perProjectSourcePath` (a
  `mkWorkspaceSourcePath` filtered to `[projectDir] ++ resolvedDeps`) feeds
  `craneLib.mkDummySrc { src = perProjectSourcePath; }`; the real-derivation
  fallback keeps IFD-freedom where no path is available.
- `mkTrunkProject`: same pattern, and a path `buildSrc` is now dummied by crane
  rather than passed verbatim as `dummySrc`.
- `mkCraneRustPackage`: a fetched (`derivation`) `attrs.src` still uses
  `dummySrc = attrs.src` (documented no-IFD vs cache tradeoff); a path `src` is
  dummied by crane.

### W9 - Isolated / fallback paths

- `projectDir = null` (e.g. `hello-rust-isolated`, `nestedRustPackage`): keep
  current behavior.
- `craneLib == null`: keep `rustPlatform.buildRustPackage` fallback.
- `build != null`: `rustBuildPlan` is already skipped; unaffected.
- Non-member `projectDir`: `workspaceMode` is false, so the legacy per-package
  source/deps path runs.

### W10 - Feature normalization (measured; partial fix)

Measured (2026-09): residual recompiles are of two kinds.

- **Transitive union (not fixable by normalization).** The base (`--workspace`,
  which also builds dev-deps via `cargo test --no-run`) unions features
  requested by _other_ members, so `syn` is built with
  `extra-traits`/`fold`/`visit`/`visit-mut` that a narrower member build does
  not request, then `syn -> clap_derive`/`serde_derive` -> `clap`/`serde`
  recompile.
- **Direct divergence (fixable by normalization).** Members disagree on a shared
  dependency's own features: `abird-host-agent`/`abird-host-manager` request
  `clap = ["derive","env"]` while `nats-http-bridge`/`nats-wrecking-ball`
  request `["derive"]`, so the bridge/wrecking layers recompile
  `clap`/`clap_builder`.

Normalizing `[workspace.dependencies]` features removes the direct divergence
but not the transitive union; the transitive part is fixed by per-demand groups
(Design F). **Partially deferred:** the base's union is the correct L behavior
and does not affect correctness; direct-feature normalization is a possible
follow-up.

### W11 - Diagnostics (landed)

- `passthru.memberLayer`, `passthru.sharedDepsBase`, and `passthru.projectDir`
  are exposed to inspect sharing (the first two enable a future assertion that
  every member reports the same base drv).
- A read-only `rustWorkspacePlan` flake output printing the member list and
  edges (seed for Design F's planner) is still optional/not implemented.

## Edge cases and risks

- **Compile-time native inputs for externals.** `depsBase` is canonical and must
  not carry per-package `nativeBuildInputs`/`buildInputs`. Today no external
  needs them (`reqwest` uses `rustls-tls`), but if one appears, add a canonical
  `depsNativeBuildInputs`/`depsBuildInputs` at the workspace level rather than
  per package.
- **`nativeCheckInputs`.** Excluded from `depsBase`; `buildDepsOnly` only
  compiles tests (`--no-run`), and the per-package checks still receive them.
  Re-add centrally if a dev-dependency needs a native input to compile.
- **Feature mismatch.** Residual recompiles unless W10 is done. Measure before
  and after.
- **`env!` / compile-time attrs.** They belong to the member's own layer (the
  package), so they are not part of `depsBase`; the member crate compiles once
  with them.
- **`doCheck = true` members** run tests inside the layer; `depsBase` already
  cached dev-deps.
- **Join cost (W7).** Full archive per fan-in; only for >= 2 internal deps.
- **Source filter drift.** If a member is added to `Cargo.toml` but its files
  are filtered out, `-p` fails; keep the filter derived from the same member
  list.
- **Platform gating.** Members with `meta.platforms` restrictions must not break
  `--workspace` on unsupported hosts; filter members per `hostPlatform` in W1 if
  a platform-specific member is added.
- **Legacy `cargoWorkspacePrePatch` awk.** It assumes a multi-line
  `members = [...]` array; a single-member workspace is serialized inline and
  would break the legacy `-deps` build. Pre-existing and not reachable in this
  repo (five members); fix the rule if a single-member workspace appears.
- **Transitive feature recompiles.** The base unions features from other
  members' graphs, so a member layer can recompile a few shared units (`syn` and
  its dependents). Correct, not free; Design F addresses it (see W10).

## Validation

- **No IFD:**
  `nix eval --option allow-import-from-derivation false --raw
  .#abird-host-manager.drvPath`
  (and every workspace package) succeeds.
- **Source invariance:** capture `nix eval --raw
  .#abird-host-manager.drvPath`
  and the `-deps`/`depsBase` drv path, append two lines to
  `pkgs/tools/abird-host-manager/src/progress.rs`, re-evaluate: `depsBase` must
  be unchanged; only the member package drv changes.
- **Sharing count:** across the five workspace packages there is exactly one
  shared `abird-rust-workspace-deps` base drv. Member sources are intentionally
  per-member (one `cargo-workspace-source` each) plus the whole-workspace dummy
  used by the base (verify with `nix derivation show -r` / `nix-store -q`).
- **Minimal recompile:** after an edit to `abird-host-agent`, the manager layer
  recompiles `abird-host-agent` once and nothing else recompiles it; after an
  edit to `abird-host-manager`, no external crate recompiles.
- **Correctness:**
  `nix build .#abird-host-manager .#abird-host-agent
  .#nats-http-bridge .#nats-wrecking-ball .#example-hello-rust`
  and their checks; `cargo test -p ...` via the crane `checks.test`.
- **Closure size:** `nix path-info -S` before/after. The deployed package must
  not reference the dependency archive (only `memberLayer` does); per-package
  runtime closure should shrink, not grow.
- **Fan-in (W7) probe:** temporarily give a package two `internalDeps` (pass
  `helloRust = packages.example-hello-rust` through `manifest.nix` and set
  `internalDeps = [ abirdHostAgent helloRust ]`), build it, then revert.
  Confirms `mkCargoArtifactsJoin` builds a full archive and the member still
  compiles once.

## Rollout and rollback

- **L0 (W8):** landed (legacy `dummySrc` fix).
- **L1 (W1-W5):** landed (shared base + member layers).
- **W7 (join):** landed (`mkCargoArtifactsJoin`, probed). This is not the design
  plan's "L2" (that label is the planner diagnostic, W11).
- **W10:** deferred (transitive feature unions; see W10).
- **Rollback:** `useWorkspaceDeps = false` restores the legacy per-package path
  without reverting code; a dependency rolled back this way degrades (its
  `memberLayer` is absent and dependents compile it from source).

## Open decisions

- W6 shape: pass the dependency's package derivation (explicit, exact, small
  manifest change) versus derive edges from a pure planner (more automatic,
  needed for Design F). Recommend explicit now, planner at F.
- Fate of the `deps` argument: keep as advisory for the legacy path, or remove
  from workspace members.
- W7 now versus when the first >= 2-edge member appears.
- W10 now versus after measuring residual recompiles.
- Where `sharedDepsBase` lives: local `let` (relies on hash-consing, current
  recommendation) versus a memoized `pkgs` attribute.

## File map

- `lib/flake/pkg-helper.nix`: W1, W2, W3, W4, W7, W8, W11.
- `pkgs/manifest.nix`: W6 (`args` for `abird-host-manager`).
- `pkgs/tools/abird-host-manager/default.nix`: W6 (`internalDeps`, `deps`
  cleanup).
- `pkgs/tools/abird-host-agent/default.nix`: `nativeCheckInputs = [pkgs.rsync]`
  for the transfer tests' `rsync` lookup.
- `Cargo.toml`: W10 (feature normalization).
- Validation probes: `pkgs/tools/abird-host-manager/src/progress.rs` (temporary
  edit, restore afterwards).

## References

- Design and rationale:
  `.agents/docs/plans/rust-workspace-build-graph-2026-09.md`.
- Decision log:
  `.agents/docs/notes/tooling/rust-build-graph-decision-2026-09.md`.
- Crane internals read for this plan: `lib/buildDepsOnly.nix`,
  `lib/buildPackage.nix`, `lib/mkCargoDerivation.nix`, `lib/mkDummySrc.nix`,
  `lib/setupHooks/inheritCargoArtifactsHook.sh`,
  `lib/setupHooks/installCargoArtifactsHook.sh`.
