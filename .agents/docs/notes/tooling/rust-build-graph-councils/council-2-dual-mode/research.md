# RESEARCH: Rust build-cache architecture under G10/G11 (mirrored package flakes)

Researcher lane, 2026-09-30, repo `0711cc31` (read-only). Web access
**available** (nix.dev + flake.parts fetched). Scratch: `tmp/design-f2/`; flake
mechanics were evaluated from `/tmp/f2exp` (copied to
`tmp/design-f2/flake-exp/`) because Nix requires path-input files to be
git-tracked and `tmp/` is not.

Method: read the four listed docs plus `pkg-helper.nix`, `root.nix`,
`default.nix`, `packages.nix`, crane source in the store
(`/nix/store/7rradzysxg41b2yx7qnh2f2bw73py192-source`), and ran isolated flake
composition experiments plus live `nix eval`/`nix derivation show` probes.

---

## 1. Flake composition mechanics (path vs flake inputs, follows, override)

**1.1 — all composition primitives needed for a swap work.** Verified with
pure-data flakes:

- `inputs.pkg.url = "path:/abs/dir"` is a real input; transitive inputs lock
  (`pkg/lib` appears in the consumer lock).
- `{ url = "path:/abs/dir"; flake = false; }` yields the raw source tree as a
  store path (`builtins.readFile (plain + "/f")` works).
- `path:/abs/dir?dir=pkg` selects a subdirectory as the flake root.
- `inputs.pkg.inputs.lib.follows = "lib"` aligns a transitive input.
- `nix eval --override-input pkg path:/abs/other '.#external'` swaps for one
  command with no file edit and no lock write (with `--no-write-lock-file`).

Evidence:
`/tmp/f2exp/{lib,pkg,consumer,consumer-follows,consumer-plain,consumer-subdir,consumer2}`
(→ `tmp/design-f2/flake-exp/`); nix.dev `nix3-flake` lists `follows`,
`override-input`, and `path`/`git`/`flake=false` input types. Confidence: high.

**1.2 — relative `path:` inputs misresolve.** `inputs.lib.url = "path:../lib"`
inside a flake raised
`access to absolute path '/nix/store/lib/flake.nix' is
forbidden`: Nix resolves
it relative to the _copied_ flake root (`/nix/store/<hash>-source/../lib`), not
the CWD. Use absolute paths, `git+...?dir=`, or `file:` URLs; never relative
`path:`. Confidence: high (direct experiment).

**1.3 — path inputs inside a git repo require tracked files.** A flake under the
gitignored `tmp/` failed with `Path '...' is not tracked by Git`. Any in-repo
`path:` mirror input must be `git add`ed. Confidence: high.

**1.4 — a one-line declarative swap needs a composition seam.** The chain is
`lib/flake/packages.nix:20-56` (`callPackage entry.path`), driven by
`pkgs/manifest.nix`; nothing can see a flake input today. Minimal seam: a
defaulted `externalPackagesFor ? _system: {}` threaded
`flake.nix -> root.nix -> default.nix -> withPkgs -> packages.nix`, so a swap is
two lines in `flake.nix`. `--override-input` gives a one-line _temporary_ swap.
Do not rely on `manifest.nix` (pure data, no flake access) or on `args` (sees
only sibling packages).

**1.5 — `follows` is necessary but not sufficient.** Aligning `nixpkgs`,
`crane`, and (if used) `lib/flake` makes identical source produce the same
`pkgs.craneLib`; a mirror that re-resolves its own `Cargo.lock` or changes
`resolver` still diverges at the cargo layer. Share pins _and_ lock.

---

## 2. Extracting `lib/flake` as an isolated library flake

**2.1 — `pkg-helper.nix` is almost self-contained but has four relative-path
escapes.** It has **no sibling `import`s** (grep for `import` returns none),
but: `repoRoot = builtins.toString ../..` (`:11`), `../../treefmt.toml`
(`:474`), default `src = ../..` in `mkTrunkProject` (`:1529`) and
`mkRustDerivation` (`:2116`). As a flake input these resolve against the store
copy root; I verified `../..` from a flake source prints `/nix` **without
error**, i.e. it silently points outside the library. Extraction must
parameterize `repoRoot`/`src`/`treefmtConfig` and delete the escapes.
Confidence: high (`/tmp/f2escape`).

**2.2 — the faithful library is much larger than `pkg-helper.nix`.** Every
per-package `flake.nix` imports `lib/flake/stack/package.nix`, which imports
`service-module.nix` (1215 lines) at module scope; Rust packages use
`srv.mkModule` / `srv.mkIdentity` / `srv.mkServicesModule` in `extraPassthru`
(`hello-rust`, `hello-rust-isolated`, `nats-wrecking-ball`, `nats-http-bridge`).
`stack/package.nix` builds `srv` eagerly, so even packages that never call it
pull the service stack. A Rust-only mirror can bypass `stack/package.nix` and
call `pkgHelper.mkStdFlakeOutputs` directly, but loses `nixosModules`.
Confidence: high.

**2.3 — repo-blindness is already the stated target.**
`package-project-boundaries.md` "Desired future shape": `lib/flake` becomes its
own standalone flake input, child flakes depend on it, "unless the package
intentionally needs monorepo source such as the root Cargo workspace".
`lib/flake/packages.nix:5` hard-imports `../../pkgs/manifest.nix`, so the
library flake must keep manifest/composition injected (as `shared-test-areas.md`
already does for checks). Confidence: high.

**2.4 — version skew has two existing answers.** (a) A flake input pins one rev;
`follows` aligns only transitive inputs, not the library itself, so mirrors can
drift. (b) The repo already practices **byte-identical shared areas across
repos** (`shared-test-areas.md`): copy `lib/`/`pkgs/`/`scripts/` bytes and port
explicitly. That is a proven, churn-controlled alternative to a library flake
and sidesteps the escape problem. Implication: extraction is optional; a
vendored helper with parameterized `src` is the lower-risk start.

**2.5 — a standard library cannot supply `src` for a mirror.** The `src = ../..`
default infers the monorepo root. In a mirror the package is at the repo root,
so `projectDir` must become `"."` (or be injected) and `src` must be the mirror
root. `mkRustDerivation` accepts `src`, but every `pkgs/**/default.nix`
hardcodes the monorepo-relative `projectDir` (5 files, e.g.
`pkgs/tools/abird-host-agent/default.nix:9`), and `abird-host-manager` hardcodes
`deps = ["pkgs/tools/abird-host-agent"]`
(`pkgs/tools/abird-host-manager/default.nix:22`). That is the per-package
divergence G10 forbids. Confidence: high.

---

## 3. Composition-independent package semantics

**3.1 — landed L is _already_ composition-independent for the deployed member.**
The member builds with `cargo <build> --offline -p <m>` and no `--workspace`
(`defaultCargoPackageArgs` `:33`, `craneWorkspaceCargoArgs` `:37`,
`resolvedCraneBuildCargoArgs` `:2290`, `memberLayer` `:2400`), and its source is
filtered to `[projectDir] ++ deps` with the root `members` list rewritten
(`mkCargoWorkspaceSource` `:102`, `cargoWorkspacePrePatch` `:235`, `buildSrc`
`:2261`). The deployed crate's feature/version resolution therefore depends only
on its component manifests, not peers. The union base is a _cache hint_;
mismatches recompile, they do not change the binary. Confidence: high. This is
the nuance the goals note does not separate from REWEAVE.

**3.2 — REWEAVE is what makes semantics peer-dependent.** Its member manifest is
rewritten to the shard's external union (`tmp/design-f/final-plan.md` §4.7,
`canonicalManifest`), so effective features become a function of which peers are
in the shard. Under G11 that is disqualifying unless the union is the package's
own canonical declaration. G10/G11 push back toward L's per-member `-p`
resolution, not REWEAVE's rewrite. Confidence: high.

**3.3 — what breaks standalone==merged here:**

| coupling                                            | evidence                                                           | effect                                                                                |
| --------------------------------------------------- | ------------------------------------------------------------------ | ------------------------------------------------------------------------------------- |
| `[workspace.dependencies]` (`{ workspace = true }`) | `Cargo.toml:11-38`; every member uses it                           | standalone needs a synthesized root; flattening changes manifest bytes → fingerprints |
| single shared `Cargo.lock`, `resolver = "3"`        | root; `Cargo.toml:2`                                               | versions are the union resolution; re-resolution can move patches → different binary  |
| in-repo path dep `manager -> agent`                 | `pkgs/tools/abird-host-manager/Cargo.toml:8`; `Cargo.lock:19-22`   | mirror unit is the path-connected **component**, not one crate                        |
| `default-features = false` (`reqwest`, `ssh-key`)   | `Cargo.toml:23,30`                                                 | polarity must survive; flattening can silently widen                                  |
| dev-deps + native check inputs                      | `tempfile` (agent); `rsync`/`jq`/`nats-server`/`bash`/`util-linux` | mirror must carry them or tests differ                                                |
| root `[patch]`/`[replace]`/`[workspace.package]`    | **absent** (grep)                                                  | not a breaker today; REWEAVE still plans a split                                      |

**3.4 — the lock is the main remaining coupling.** Because the member's root
`members` is rewritten, the only monorepo-global inputs are `Cargo.lock` and
`[workspace.dependencies]`. A mirror that copies the exact lock and the used
workspace entries reproduces the member's resolution byte-for-byte; one that
re-resolves does not. The generator must copy the lock (a component-filtered
superset is fine), and a peer's dependency addition can move a mirror until it
is regenerated. Confidence: high.

**3.5 — W10 normalization should precede mirroring.** It removes the measured
direct `clap` divergence without changing any member's own declaration (the
union table is already a superset). The transitive `syn` residual is not fixable
without component-scoped bases (Finding 4). Confidence: high.

---

## 4. Artifact / cache sharing between standalone and monorepo

**4.1 — the monorepo shares exactly one base today.** Live:
`abird-host-agent.passthru.sharedDepsBase.drvPath` ==
`nats-http-bridge.passthru.sharedDepsBase.drvPath` ==
`/nix/store/wp01m3cy7j5skpm36dzx0lw63h4znfyg-abird-rust-workspace-deps-0.1.0.drv`.
`mkSharedRustDepsBase` (`:179`) takes canonical args only; Nix hash-conses one
drv. Confidence: high.

**4.2 — that base is keyed on the _whole_ workspace.** Built from
`mkRustWorkspaceSource` (`:167`) with `selectedDirs = rustWorkspaceMembers` (all
members) and `cargoExtraArgs = "--offline --workspace"` (`:179-195`). Any
member-manifest change changes the dummy source and the base drv. A
single-package mirror cannot reproduce it without the monorepo's full member
manifest set. Confidence: high.

**4.3 — reuse requires the _exact same_ `cargoArtifacts` drv; no
content-addressed cross-derivation dedup.** Crane's `inheritCargoArtifactsHook`
decompresses/symlinks the whole inherited target dir;
`installCargoArtifactsHook` stores a delta archive with a `.prev` symlink. Two
derivations building the same crate from different bases do not share rlibs at
the Nix level. Confidence: high (crane source read).

**4.4 — fingerprint identity is load-bearing and already handled.** `mkDummySrc`
derives the dummy output name from the input source basename (`mkDummySrc.nix`
`sourceName`); both `mkWorkspaceSourcePath` (`:67`, default
`name = "cargo-workspace-source"`) and `mkCargoWorkspaceSource` (`:102`) use it,
so base dummy and member real source both unpack to
`/build/cargo-workspace-source`. Vendor identity is `vendorCargoDeps` hashing
`cargoLockContents` (`crane/lib/vendorCargoDeps.nix`): identical lock text →
identical vendor drv. These are the levers that make equality possible.
Confidence: high.

**4.5 — sharing the monorepo base with a mirror requires passing it in, or
component-scoped bases.** Two coherent designs:

- **B-comp (component base):** one `buildDepsOnly` per path-connected component,
  keyed on the component's real manifests. The monorepo member build and a
  standalone mirror of the same component then produce the _identical_ base and
  `memberLayer` drvs (same source, lock, args), so the monorepo can substitute
  the mirror's package exactly. Cost: no cross-component sharing — measured Plan
  B `{0,65,216,233,239}`, sum 753 vs union 367 (~2.05×).
- **B-shared (base-as-input):** expose the base (or a deps flake) as a flake
  output and give `mkRustDerivation` a `base ? null` / `cargoArtifactsBase`
  argument. The monorepo passes its base; the mirror passes its own when
  standalone. Keeps the 367-compile speed and exact reuse when the monorepo
  drives the build, but the mirror alone is not independently reproducible.

G11's "same artifact sharing" is fundamentally in tension with the union base;
pick B-comp (mirror-identical, slower) or B-shared (fast, base is a monorepo
artifact). A hybrid — component bases for shared components, union only inside a
component — is the principled middle. Confidence: high for mechanics, medium for
the 24-member cost extrapolation.

**4.6 — native-input coupling is a latent scalability bug at 24 members.**
`mkSharedRustDepsBase` deliberately takes no per-package `nativeBuildInputs`; if
any of 24 packages needs one to compile a _dependency_, the shared base is wrong
for it. Today only `nativeCheckInputs` are used (tests), so it is latent.
Confidence: high.

---

## 5. Prior art (local + external)

**5.1 — the 13 existing per-package `flake.nix` files are _not_ G10 mirrors.**
They `import ../../../lib/flake/stack/package.nix` by relative path and rely on
`pkg-helper.nix`'s `../..` default `src`, so they evaluate against the monorepo
tree. Worse, `stack/package.nix` supplies no crane overlay, so
`pkgs.craneLib == null` and `mkRustDerivation` falls back to
`rustPlatform.buildRustPackage`. Live on `pkgs/tools/abird-host-agent`: passthru
is `["checks","devShell","fmt","lint-fix","pkgOps","projectDir","sourcePath"]` —
no `memberLayer`, no `sharedDepsBase`; its drv
(`lmiifb6fcp6hvbpdg5l5rfyihb55xa5b`) has no
`cargoArtifacts`/`CRANE_BUILD_DEPS_ONLY`. `overlays/default.nix:9` adds
`craneLib` only in the monorepo. So the current child flake already violates
G11. Confidence: high (live eval + `tmp/design-f2/child-agent-drv.json`).

**5.2 — `hello-rust-isolated` is the genuine standalone template.**
`projectDir = null`, `src = ./.`, no workspace inheritance; evaluates without
the monorepo root (`pkgs/examples/hello-rust-isolated/{flake,default}.nix`). It
is the shape a generated mirror should have, but it uses the legacy path (no
crane layering) unless a `craneLib` is provided. Confidence: high.

**5.3 — local design docs already name the target and guardrails.**
`package-project-boundaries.md` "Desired future shape" is G10/G11;
`shared-test-areas.md` supplies the byte-identical multi-repo discipline;
`external-source-units.md` supplies the "convention is the discovery mechanism"
generator pattern (`sources.nix` + `update.sh` per unit, never hand-maintained).
A mirror generator should follow the same philosophy. Confidence: high.

**5.4 — external prior art.** `flake-parts` module partitioning is the common
way to give one library flake a stable helper surface; crane's
`cargoArtifacts`/`.prev` layering is the only supported cross-build cache;
cargo's `[patch]`/path-dep duality and per-crate publish are the upstream
analogue of "standalone vs merged". I found no drop-in tool that mirrors a
monorepo member into a standalone flake with shared artifacts; REWEAVE's
`union-fresh` gate is the closest correctness backstop. Confidence: medium
(nix.dev + flake.parts fetched, not a systematic search).

---

## 6. Mirroring workflow and drift control

**6.1 — the minimal standalone unit is a path-connected component.** Per mirror:
the component's crate dirs (today only `{abird-host-agent, abird-host-manager}`
is multi-crate), a root `Cargo.toml` with `[workspace]`, `resolver = "3"`,
`members`, and the used `[workspace.dependencies]`, the exact `Cargo.lock`, and
a `flake.nix`/`default.nix` with component-relative `projectDir`/`deps` and a
pinned `lib/flake` (or vendored helper). Confidence: high.

**6.2 — hand-maintaining mirrors violates G10; generate them.** The divergence
is exactly `projectDir` (5 hardcoded strings), `deps` (1 list), the synthesized
workspace root, and the lock. One generator consuming the monorepo
`Cargo.toml`/`Cargo.lock` + component graph and emitting the mirror removes all
hand-sync; it also computes the component closure, the `workspace.dependencies`
subset, and the `lib/flake` pin, and is diffable/CI-checkable. This mirrors the
`external-source-units.md` convention philosophy. Confidence: high as a
direction; generator not prototyped.

**6.3 — the mirror must not encode monorepo-relative paths.** `mkRustDerivation`
defaults `src = ../..` relative to the helper file, so the mirror must pass
`src` explicitly and derive `projectDir` from its own location, or keep a
vendored helper whose `../..` is the mirror root. The hardcoded strings are not
acceptable. Confidence: high.

**6.4 — drift detection is cheap and should be a check.** A CI check that
regenerates each mirror and diffs it (or asserts mirror package drv == monorepo
member drv) turns G11 from a hope into a gate. This is the mirror analogue of
`union-fresh` and the highest-value G10/G11 control. Confidence: high.

---

## 7. Direct implications for the design (ranked)

1. **Keep L's per-member `-p` resolution as the semantic contract; drop
   REWEAVE's union manifest rewrite.** L already gives composition-independent
   deployed binaries (3.1); REWEAVE's rewrite is the only part that makes them
   peer-dependent (3.2). Correctness first; treat the union base as a cache
   hint.
2. **Make the base strategy explicit and keyed.** Offer `union` (fast, 367, not
   mirror-identical) and `component` (2.05×, mirror-identical, exact sharing);
   do not claim one base satisfies both G10 and G11.
3. **Add a `base ? null` / `cargoArtifactsBase` seam to `mkRustDerivation`** so
   a monorepo can inject its base into a mirror-built package and a mirror can
   inject its own. Mechanical enabler for G11 sharing.
4. **Fix the swappoint now:** defaulted `externalPackagesFor` through
   `flake.nix -> root.nix -> default.nix -> packages.nix`; one input line + one
   mapping line, plus `--override-input` for temporary swaps.
5. **Mirror unit = path-connected component; copy the lock.** Generate the
   mirror; never hand-maintain `projectDir`/`deps`/root manifest.
6. **Fix `lib/flake` extraction prerequisites first:** remove the four
   relative-path escapes, parameterize `src`/`repoRoot`/`treefmtConfig`, keep
   composition injected; choose vendored-sync vs pinned flake input (if the
   latter, `follows` nixpkgs+crane+lib).
7. **Do W10 normalization; add mirror-drift and mirror==member drv checks.**

## 8. Could not verify / open

- I did not build a real crane standalone mirror end-to-end (needs a synthetic
  second repo with the full `[workspace.dependencies]` + lock); drv-identity
  claims are inferred from code + crane internals + the live shared-base probe.
- The 24-member cost curve is an extrapolation of the 5-member measurement
  (`{0,65,216,233,239}`, sum 753 vs 367) in `tmp/design-f/final-plan.md`.
- `nix flake check` on a _synthetic_ mirrored manager repo was not run; only the
  existing in-tree child flake was probed.
- External prior-art survey was shallow (nix.dev + flake.parts).
- Whether Nix 2.34 should _error_ on flake-relative escapes rather than silently
  resolving to `/nix` is unclear; the silent misresolution is the safe
  assumption.

## 9. Experiment index

- `tmp/design-f2/flake-exp/` — path input, `flake=false`, `dir=`, `follows`,
  `override-input`, relative-path failure (evaluated from `/tmp/f2exp`).
- `tmp/design-f2/child-agent-drv.json` — child-flake agent drv (no crane).
- `tmp/design-f2/exp/` — first (git-blocked) attempt.
- Live probes: `sharedDepsBase` equality across members; child-flake passthru.
