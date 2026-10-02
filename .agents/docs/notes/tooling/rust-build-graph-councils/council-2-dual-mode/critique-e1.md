# Critique — Candidate E1 "L-KEEP" (Council 2, harsh)

Reviewer: council 2. Repo read-only at `0711cc31` (+dirty). Scratch
`tmp/design-f2/`. Method: read `plan-e1.md` and `research.md` in full; read
`lib/flake/{pkg-helper,packages,default,root,stack/package}.nix`,
`pkgs/tools/{abird-host-{agent,manager}}/default.nix`, `pkgs/manifest.nix`;
inspected crane `rev 73b9805` (`buildDepsOnly.nix`, `mkDummySrc.nix`,
`writeTOMLViaCraneUtils.nix`, `filters/*`); live
`nix eval`/`nix derivation show`; and two controlled experiments (below).

## Experiments actually run

- **E-A (source identity).** Re-implemented `mkWorkspaceSourcePath`'s filter and
  compared the `builtins.path` store path for the component subtree from the
  _pure_ monorepo flake source `/nix/store/val6c576…-source` vs. a mirror built
  with `git archive HEAD` (only root `Cargo.toml`/`Cargo.lock` +
  `pkgs/tools/abird-host-{agent,manager}`). Result: equal
  (`ssrz1dim…-cargo-workspace-source` for agent; `jrlc1r3i…` for
  {agent,manager}). The real member build uses exactly `ssrz1dim…` (traced via
  `…-abird-host-agent-build-0.1.0.drv → y6nfhrv…-cargo-workspace-source.drv → env.src`),
  so the layout-preserving source claim is _achievable_ for tracked bytes.
- **E-B (component base identity).** Built the §5.1 `componentBase` recipe
  (`mkWorkspaceSourcePath` + `mkDummySrc` + `buildDepsOnly`, prePatch to
  component dirs, `--offline --workspace`, same lock/vendor) from the monorepo
  source and from the mirror source with the same `pkgs`. drvPath identical:
  `q8j66jz3dlcf3alvhlbqswad6wvnygw6-abird-rust-agent-deps-0.1.0.drv`.
- **E-C (trap).** The working tree contains gitignored
  `pkgs/tools/abird-host-agent/flake.lock` (`git check-ignore -v` →
  `.gitignore:10:flake.lock`). An _impure_ source `/nix/store/92kph…-source`
  contains it; the pure flake source `/nix/store/val6c…-source` does not. A
  generator that copies the worktree diverges from the source the build actually
  evaluates.
- **E-D (prePatch format).** `crane-json2toml` emits `members = [` / 4-space
  entries / `]`, so the awk in `cargoWorkspacePrePatch` is safe on
  `mkDummySrc`'s regenerated root manifest.

Net: the _core_ drv-equality mechanism works for the `{agent,manager}` component
under the stated conditions. The problems are in the seams the plan leaves
underspecified.

---

## Ranked issues

### BLOCKER-1 (as literally specified): injected `base` never reaches `mkRustDerivation`

**What.** §4.4/§5.3 add `pkgHelper`/`src` to `packagesFn`, but the pseudo-code
keeps `pkgs.callPackage entry.path (stackArgsFor … // entry.args …)`.
`pkgs/**/default.nix` declares
`pkgHelper ? import ../../../lib/flake/pkg-helper.nix` and `packages.nix` passes
neither `pkgHelper` nor `defaultBase`. `packages.nix:22-40` shows `stackArgsFor`
is the _only_ injected attr, and `lib/flake/default.nix:24` imports the helper
bare. **Why.** If `callPackage` is not handed `pkgHelper`, the default import
runs with `defaultBase = null`; the mirror's `mkPackage { base }` and the
monorepo's `defaultBaseStrategy`/`base` never reach the build. Then GATE-M/union
and the whole `base` seam silently no-op (worst: component mode still works, so
the gate passes while union sharing does not). **Fix.** `packages.nix` must
accept `pkgHelper` and set
`args = (stackArgsFor entry.path) // { pkgHelper = pkgHelper; } // (entry.args …)`
(or add `pkgHelper` to `packagePkgs` before `callPackageWith`). Add
`defaultBaseStrategy` alongside `defaultBase` in §4.1 so the monorepo can stay
`union` without per-`default.nix` edits.

### P1-2: component base's `nativeBuildInputs`/`buildInputs` union is unimplementable from one member

**What.** §9 requires `profileFor(component)` = union of all component members'
`nativeBuildInputs`/`buildInputs`. But `componentBase` is computed _inside_ each
member's `mkRustDerivation`, which only sees its own `buildAttrs`.
`lib/flake/rust-components.nix` reads only `Cargo.toml`; it has no access to
`default.nix` build attrs. `agent` (no build inputs) and `manager`
(`buildAttrs.nativeBuildInputs=[pkgs.makeWrapper]`, `postInstall`,
`doCheck=false`) would compute **different** `componentBase` drvs unless
`buildAttrs` is ignored — and if ignored, a dep that needs a tool to _compile_
fails in the base or silently skips caching (the latent 24-member bug from
research §4.6). This breaks the plan's own word "canonical" and can pass a base
missing inputs to a sibling's layer. **Fix.** Compute the component base in the
composition layer (once, from the component's members' profiles) and pass it
down via `component`/`base`, or make the base deliberately profile-free
(dependency-only) and document that no member may need a build input to compile
a _dependency_ — verifying that for all 24 members and adding a gate. Do not
leave `profileFor` as a member-local concept.

### P1-3: "behavior unchanged (union)" in E0 contradicts the hard default `baseStrategy="component"`

**What.** §4.2 sets `baseStrategy ? "component"`; §14 E0 says "behavior
unchanged (`union`)". Nothing in `default.nix` passes `baseStrategy`, so the day
§4.2 lands, every package flips to component mode simultaneously: repo-wide
cache invalidation and the ≈2.05× cost, before any mirror exists. **Fix.** Add
`defaultBaseStrategy ? "union"` to the helper instantiation (§4.1) and let only
the mirror set it to `component`; flip the monorepo per component later. Define
the per-component flip mechanism explicitly (the plan's migration table asserts
it but no code path selects strategy per component).

### P1-4: generator source-of-truth must be the evaluator source, not the worktree/`cp -a`

**What.** E-C: the worktree contains gitignored files under component dirs
(`pkgs/tools/abird-host-agent/flake.lock`); the pure flake source does not.
§7.2/§10.2 say "byte copy" but never say _of what_. Copying the worktree
includes ignored files and makes `mirror-fresh` non-reproducible (local vs CI);
copying `git archive HEAD` while the monorepo builds the dirty worktree also
diverges. `builtins.path` selects the **whole** component dir, so any extra byte
changes the member drv. **Fix.** Generate strictly from
`git ls-files`/`git archive` of the exact revision the parity gate evaluates,
and have `mirror-fresh` compare against the same (flake/tree) source; explicitly
forbid worktree copies.

### P1-5: mirror standalone build must wire crane/nixpkgs, or G10 is hollow

**What.** The existing per-package `flake.nix` wrappers evaluate with
`craneLib == null` and fall back to `rustPlatform.buildRustPackage` (research
§5.1) — a different derivation. §4.6 only mandates that `mkPackage` _accept_
consumer `pkgs`; the generated mirror flake's own `pkgs` used by
`nix build .#default` is unspecified. If it is
`nixpkgs.legacyPackages.${system}` without the crane overlay, the standalone
package is not the monorepo member, GATE-M would only test the injected-pkgs
path, and the goal "standalone-buildable flake" is technically met while the
substance is not. **Fix.** Specify the generated flake to build `pkgs` with
`crane.mkLib` (or expose `craneLib`) and `follows` nixpkgs/crane; add a gate
that `mirror.packages.<system>.<name>.drvPath` (standalone) equals
`monorepo.packages.<system>.<name>.drvPath` after the component flip, not only
the `mkPackage` path.

### P1-6: the three `srv` members cannot mirror with "same `default.nix`" and a Rust-only bypass

**What.** `hello-rust`, `nats-http-bridge`, `nats-wrecking-ball` import
`../../../lib/flake/stack/package.nix`, which eagerly builds
`service-module.nix`; their `extraPassthru` call
`srv.mkModule`/`mkServicesModule`/`mkIdentity`. §11.3's "Rust-only mirrors
bypass `stack/package.nix`" is impossible while keeping the same `default.nix`
(the import is in the file). So mirrors of 3 of 4 components must vendor
`pkg-helper.nix` + `service-module.nix` + `stack/package.nix` (+
`stack/build-set.nix`, `stack/lib.nix` if referenced), not a neat "Tier 1
helper" and not `lib/flake/**` (which drags
`root.nix`/`configuration-family.nix` that `import ../validation` and
`../tests`, absent in the mirror). **Fix.** State the exact per-component
vendored file closure; or generate a `stack` shim in the component manifest
(`entry.args` can override `stack`) instead of pretending the same `default.nix`
avoids the service stack. Reconcile §11.3 with §5.3.

### P1-7: GATE-M union identity needs `base` threaded to in-component siblings

**What.** §8.2 tests
`mirror.mkPackage { pkgs; base = member.sharedDepsBase } == member`. For
`abird-host-manager`, `dependencyArtifacts` is `agent.passthru.memberLayer`
(`pkg-helper.nix:2380-2400`), not `base`. Identity holds only if the injected
`defaultBase` also reaches the mirror's `abird-host-agent` (so agent's layer is
union-based). §4.4's external function form hard-codes `base = null`, and no
text threads `base` to in-repo mirror members. **Fix.** Mirror composition must
instantiate one `pkgHelper` with `defaultBase = base` for _all_ mirror members
(not only the replaced top-level one), and the gate must build manager, not just
agent.

### P2-8: `base`/`baseStrategy`/`component`/`mirrorUnit` leak into `buildArgs`

**What.** `pkg-helper.nix:2205-2230` computes
`buildArgs = removeAttrs args […]`; the new args are not in the removal list.
`base` (a derivation) then becomes an attribute of `craneCommonAttrs`, i.e. an
extra input/env of `cargoBuild`/`buildPackage`, adding the base to the member's
direct inputs and closure. `base=null` is dropped, but external/union modes keep
it. **Fix.** Add the four new names to the `removeAttrs` list.

### P2-9: "component mode cost ≈ 2.05×" is a 5-member extrapolation

**What.** `research.md` §4.5/§8 and `tmp/design-f/final-plan.md` measured
`{0,65,216,233,239}` (753) vs union 367 at 5 members. With 24 members, mostly
singleton components, each singleton base recompiles the whole external dep set
under a distinct derivation hash: the true cost can approach "once per
component", not 2×. The plan admits the lever but still foregrounds 2.05×.
**Fix.** Re-measure on a synthetic N-component repo before declaring component
the default; state the worst-case bound (one external-dep compile per component)
and gate the component default on a measured budget.

### P2-10: mirror root `members` points at absent dirs → not self-contained outside Nix

**What.** §7.2/§17.4: root `Cargo.toml` is a byte copy listing all 5 members
while only the component dirs exist; correctness relies on `prePatch` inside
every Nix build. Plain `cargo` in the mirror (e.g. inside a `nix develop` shell)
fails to resolve the workspace. `nix build`/`checks` work because crane applies
`prePatch`. **Fix.** Either generate a component-filtered root `Cargo.toml`
(still drv-safe if the member build's `prePatch` yields the same bytes — but
then the base's dummy source changes; verify) or explicitly scope G10 to Nix
builds and omit a dev shell from the mirror contract.

### P2-11: Tier-2 `lib` flake input will not be used by direct-import packages

**What.** `abird-host-{agent,manager}/default.nix` import
`../../../lib/flake/pkg-helper.nix` via the function default; even if the mirror
adds `inputs.lib`, `callPackage` never supplies `pkgHelper`, so the input is
ignored. §11's `defaultSrc` argument only works if the injected helper is
actually threaded (same root cause as BLOCKER-1). **Fix.** Make `packages.nix`
inject `pkgHelper` (BLOCKER-1) so an external `lib` input can replace the
vendored helper; otherwise drop the Tier-2 claim.

### NOTE-12: `componentKey`/pname and dir ordering undefined

`pname = "abird-rust-${componentKey}"` and the base drv depend on
`componentDirs` ordering and `componentKey`. The plan says "sorted,
deterministic" but does not define `componentKey`. Two members of the same
component must derive the identical key/base; pin the definition (e.g.
`lib.concatStringsSep "+" dirs` hashed) and test it in S1.

### NOTE-13: component-mode `sharedDepsBase` is computed needlessly and is mirror-local

`rustBuildPlan` defines `sharedDepsBase` whenever `workspaceMode` holds
(`pkg-helper.nix:2320-2360`), even when `baseStrategy="component"` and
`prefixNode` ignores it. In a mirror its `mkRustWorkspaceSource` selects the
byte-copied `members` (all 5) but only the component exists, producing a
different, unused drv. Make it lazy/null in component mode to avoid confusion
and wasted eval.

### NOTE-14: `componentBase` source name vs member source name

Confirmed load-bearing and consistent: both `mkWorkspaceSourcePath` and
`mkCargoWorkspaceSource` produce `cargo-workspace-source`; `mkDummySrc`'s
`sourceName` regex yields the same basename, so `/build/cargo-workspace-source`
and `CARGO_MANIFEST_DIR` align. This part of the plan is solid and is what makes
E-B pass.

---

## What E1 gets right (and should keep)

1. **Keeps L's `-p <member>` resolution** and refuses union manifest widening:
   deployed semantics stay composition-independent (research §3.1-3.2). This is
   the correct spine for G10/G11.
2. **Layout-preserving mirror + byte-copied root manifest/lock is the right and
   empirically sufficient mechanism** for drv identity. E-A/E-B show identical
   filtered source and identical component-base drv for a `git archive` mirror
   with the same `pkgs`. The plan's §5.4 identity conditions are essentially
   correct; the load-bearing `sourceName`/dummy/fingerprint details are real and
   verified.
3. **Per-component base as the sharing unit** is a genuine advance over the
   monorepo-keyed union base and is the only way to get mirror-identical
   artifacts.
4. **`base`-injection is the right escape hatch** for union-speed monorepos and
   exactly matches what crane can actually do (research §4.3-4.5); the
   union-base output (§4.5) is the correct carrier.
5. **`externalPackagesFor` by manifest name** is the minimal, low-churn seam;
   `--override-input`, `follows`, `flake=false`, `?dir=` mechanics are proven
   (research §1).
6. **Generated mirrors + `mirror-fresh`/`mirror-parity` gates** are the right
   discipline and convert the G11 claim into a check rather than a hope.
7. **No IFD by construction**; degradation always falls back to L. The risk
   posture is honest.

## One-line verdict

E1's core
(`layout-preserving mirror → identical source → identical component base → identical
member`)
is _demonstrably achievable_ (E-A/E-B), but the plan as written does not
actually connect the `base` seam to `mkRustDerivation` (BLOCKER-1), cannot
compute the canonical component base from a single member (P1-2), silently flips
the whole monorepo to component mode (P1-3), and leaves the mirror generator's
source-of-truth, standalone `pkgs`/crane wiring, and service-stack vendoring
underspecified (P1-4/5/6). Fix those five and it is a strong candidate; leave
them and GATE-M will pass only in the narrow `mkPackage`-injected path.
