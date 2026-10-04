# Critique E3 — ECHO (council 2, harsh)

Read: `tmp/design-f2/plan-e3.md` (all), `lib/flake/pkg-helper.nix`,
`pkgs/**/default.nix`, `pkgs/manifest.nix`, root `Cargo.toml`/`flake.lock`,
`lib/flake/stack/package.nix`, crane `73b9805` (`mkDummySrc.nix`,
`cleanCargoToml.nix`, `findCargoFiles.nix`). Ran a `builtins.path`
content-addressing experiment (below). Repo read-only; scratch in
`tmp/design-f2/`.

Bottom line: the _lever_ (layout-preserving mirror -> content-addressed source)
is correct and I verified the mechanism. But the design as written has at least
two spec-level BLOCKERs in its central seam and its composition code, scopes G10
to Rust only, and understates the `lib/flake` extraction surface. The "component
flake is the unit of truth" thesis is mostly branding: the monorepo imports
files, it does not compose flake outputs.

---

## BLOCKER

### B1. The injection seam is misnamed: every example passes `base`, but the new argument is `cargoArtifactsBase`

`§6.1` defines the seam as `cargoArtifactsBase ? null`. But every author-facing
example passes `inherit pkgs base` into `mkRustDerivation` (`§3.1`, twice). The
existing `mkRustDerivation` signature (`pkg-helper.nix:2108`) ends in
`... @ args`, and `buildArgs = builtins.removeAttrs args [...]` (`:2181`) is
merged into `commonAttrs` (`:2293`) and fed to crane. So an unknown `base` attr
is **not** the seam: it becomes a plain attr/input on the derivation, the seam
stays `null`, and `prefixNode` (`:2383`) falls through to `sharedDepsBase`.

Consequences, both fatal to the plan's tests:

- In a mirror,
  `sharedDepsBase = mkSharedRustDepsBase {source = mkRustWorkspaceSource pkgs src; ...}`
  (`:2348`). `mkRustWorkspaceSource` reads the **verbatim mirror root**
  `Cargo.toml` (all monorepo members) and `--workspace`s over member dirs that
  do not exist in the mirror -> `buildDepsOnly` fails at build.
- In-repo, the injected policy base is silently ignored, so Theorem A
  (`composed(mirror,U).drvPath == inRepo(U).drvPath`) is vacuous.

Smallest fix: name the argument `base` (or `base ? null`) in `mkRustDerivation`
and drop `cargoArtifactsBase` from the public surface; add an eval-time
`assert base == null || isDerivation base`. Update `§3.1`/`§6.1` in lockstep.

### B2. The composition sketch does not type-check against the stated contract

`§3.1` says `component.nix` returns `{ component = {...}; packages = {...}; }`.
`§5.3` does `inRepo = (import comp.definition { ... }).outputs;` and then
`iface.lib.mkPackage.${system}`. `component.nix` has no `outputs`, no per-system
`lib`, and the `packages` entries are unapplied functions. The mirror branch
returns real flake outputs, the in-repo branch does not: the two "normalized"
interfaces are different shapes. This is the central composition code, so the
design is not executable as written.

Also in the same block:
`internalPackages = {}; # filled from the same
component's fix` is a
placeholder. Without a `lib.fix` over the component's packages,
`abird-host-manager` gets `internalDeps = []` and compiles the agent from source
inside its own member layer instead of chaining `passthru.memberLayer` (which is
exactly what L does today via `pkgs/manifest.nix`
`args = packages: {abirdHostAgent = packages.abird-host-agent;}`). That breaks
I1 ("same call") and spike E3 for the only multi-crate component.

Smallest fix: make `mkComponentFlake` and the in-repo path call one shared
function that returns the _same_ `{ lib.mkPackage.<system>; definition; ... }`
interface, and actually implement the per-component `lib.fix` over
`internalPackages`.

---

## P1

### P1-1. G10 scope gap: ECHO is Rust-only, G10 is not

Only 6 of the 14 helper-driven `pkgs/...` packages use
`mkRustDerivation`/`mkCargoWorkspacePackage`. The other 8 (`hello-go`,
`hello-node`, `hello-python`, `hello-web-static`, `cloudflare-apps`,
`llmug-hello`, `codex-wrapper`, `nixbot`) use
`mkGo/Python/Web/StaticWeb/Trunk/ShellScript/Aggregate`. The contract
(`packages.<p>`, `lib.mkPackage`, `definition`) is defined only in terms of
`mkRustDerivation`. G10 says _each_ `pkgs/...` package must be a standalone
flake. ECHO silently narrows it. Fix: either define the contract per helper
family, or state in the goals "G10 for Rust components only" and renegotiate.

### P1-2. `src` default removal contradicts the proposed definitions

`§7.1` "requires explicit `src`" for `mkRustDerivation` (`pkg-helper.nix:2116`)
and `mkTrunkProject` (`:1529`). But `§3.1`'s definition and the existing
`pkgs/tools/abird-host-agent/default.nix` never pass `src`; they rely on the
`../..` default. In the mirror, `flake-lib`'s `../..` no longer points at the
component root. So either (a) every member `default.nix` must gain `src`, or (b)
the injected `pkgHelper` must close over `{repoRoot, src}`. ECHO does neither,
and does not count the member-definition churn in `§14.4`. Also
`deriveProjectPath` (`:11,20-21`) is used by `mkPackageOpsBundle`/`mkProjectApp`
and needs the same treatment, not just `src`.

### P1-3. "4 relative escapes" understates `lib/flake`

The "4 escapes" (`pkg-helper.nix:11,474,1529,2116`) is true only for
`pkg-helper.nix` in isolation. The `lib/flake` directory has **26** `../..`
sites, including `root.nix:66,283` (`../../overlays`, `../../hosts`),
`root.nix:288` (`../images`), `packages.nix:5` (`../../pkgs/manifest.nix`),
`lint.nix:6`, `dev-shells.nix:2`, `accounts/default.nix:5-6`
(`../../../users/...`), `default.nix:61` (`../../data/secrets/...`),
`stack/lib.nix:41,84` (`../../services/nginx/...`), `service-module.nix:188`
(`../services/abird-host-agent/...`), and all of `lib/flake/tests`. If "extract
`lib/flake`" means the directory, the blocker list and the 30–40-line estimate
are wrong. If it means only `pkg-helper.nix` + `mkComponentFlake.nix`, say so —
then the `service-module.nix` split is unnecessary and "lib/flake extracted" is
a misnomer.

### P1-4. The declared `mirrors` input cannot be "optional"

`§5.1` declares `mirrors = { url = "path:./dist/mirrors"; flake = false; }`
unconditionally and `§5.2` says to keep it "even in the default configuration".
`dist/` is gitignored (`**/dist/` in `.gitignore`) and `tmp/` cannot be a
`path:` input (research §1.3). A fresh clone / CI without `dist/mirrors` fails
to lock or eval. `--override-input mirrors ...` also requires the input to be
declared (ECHO notes this), so gating cannot be done lazily. Fix: commit a
tracked placeholder tree, or do not declare `mirrors` by default and accept that
`--override-input` is only available in the "anticipated" config.

### P1-5. `basePolicy = legacy` rollback is not bit-for-bit as claimed

`§3.1` rewrites `abird-host-manager/default.nix` from `abirdHostAgent ? null` to
`internalPackages ? {}`. `pkgs/manifest.nix` still passes
`args = packages: {abirdHostAgent = packages.abird-host-agent;}`. Under the old
manifest path the new arg is never supplied, so `internalDeps = []`, the agent
is compiled from source inside the manager layer, and the package diverges from
landed L. The rollback lever that `§13, §15` rely on is therefore broken. Fix:
keep an `abirdHostAgent ? null` compatibility argument, or also change
`manifest.nix` and stop claiming bit-for-bit legacy.

### P1-6. flake-lib skew: an integer `contract` version is too weak

`§7.2` gates mirror drift on `flake-lib.contract` (a small integer). Two
`flake-lib` revisions can carry the same contract number but different
`mkRustDerivation` bytes, so the standalone mirror and the composition can
produce different derivations while the gate passes. The composition is safe
(monorepo passes its own `pkgHelper`), but the `component` policy's Theorem B
("standalone drv == composed drv") requires byte-identical builder. Fix: gate on
the exact `flake-lib` rev/hash, not a hand-maintained integer.

### P1-7. `component.nix` imports are unapplied / paths escape

`§3.1` shows `abird-host-agent = import ../abird-host-agent/default.nix;`
without applying `{ pkgs; pkgHelper; base; internalPackages; }`, and the member
definition still contains `pkgHelper ? import ../../../lib/flake/pkg-helper.nix`
which does not exist in the mirror. Lazy defaults mean it usually does not
explode, but `§8.7`'s "no `../..` escape remains" is false at the
member-definition level, and any consumer importing the definition directly in a
mirror gets a missing-file error. Fix: ship the definition as a function of the
injected context (no relative fallback) and apply it in one place.

---

## P2

### P2-1. `passthru.sharedDepsBase` becomes a broken derivation in mirrors

With the seam fixed, `workspaceMode` is true in the mirror, so `sharedDepsBase`
is computed (`:2348`) over `mkRustWorkspaceSource` = the mirror's verbatim root
member list. It is exposed in passthru (`:2550`-ish). Building it fails
(`--workspace` over absent members). Fix: set it to `null` when
`cargoArtifactsBase != null`, and do not advertise it from the contract.

### P2-2. Lemma 1's generator rule ("tracked files") is insufficient

Experiment (`builtins.path`, filter replicated from `mkWorkspaceSourcePath`, two
roots with identical selected content):

```console
A=/nix/store/inx28sq3a5gl0zhbcccxy23xcd65i2xb-cargo-workspace-source
B=/nix/store/inx28sq3a5gl0zhbcccxy23xcd65i2xb-cargo-workspace-source   # identical
# after adding pkgs/tools/x/UNTRACKED.txt under a selected dir:
B=/nix/store/x6ch3qm3lwfvgv7zfgmw52adc3p0k3xq-cargo-workspace-source   # differs
```

So the lemma holds iff the mirror contains _every byte under every selected
dir_. The generator copies "every tracked file"; an untracked, non-gitignored
file in a member dir is in `inputs.self` (dirty flake source) but not in the
mirror -> Lemma 1 fails. Fix: generate exactly the filter's selected set (or
make CI forbid untracked files under member dirs).

### P2-3. Member wrappers are still in the source tree

Each member dir contains a tracked `flake.nix` (13 total) and some carry
`flake.lock`; `mkWorkspaceSourcePath` keeps all files under `projectDir`, so
they land in `S_c` and in the mirror. `§4.2`'s mirror layout omits them and
`§8.7`'s escape claim is false while they exist. Fix: delete the wrappers in the
monorepo (consistent with `§16`'s "wrappers are superseded") and reflect that
change in the drift baseline.

### P2-4. Component base is per-component, not per-member

`§12` claims "`nativeBuildInputs`/`nativeCheckInputs`: per-member profile is
part of the component base's arguments." `mkComponentBase` (`§6.3`) takes one
`nativeBuildInputs`/`buildInputs` for the whole component. A component whose
members need different native inputs to compile their build scripts cannot be
expressed. The base should only carry external compile inputs; member-specific
inputs stay on `cargoBuild`. Fix wording/API.

### P2-5. Eval-cost assertion is asserted, not shown

`§14.1` claims direct import is "roughly today's cost plus the contract wrapper"
while `flake=false` re-runs `mkComponentFlake` per component and `flake=true` is
reserved. E7 is the right spike, but the plan asserts the result before E7. Keep
it as an open question, not a claim. (Nix does memoize
`inputs.nixpkgs.legacyPackages.${system}` across calls on the same attrset, so
this may well be fine — but it is unmeasured.)

### P2-6. `--locked` on rewritten member lists is a research hand-wave

`mkComponentBase` uses `--locked` (`§6.3`) while the existing union base does
not (`:179`). The claim rests on research's "locktest2". It is plausible
(removing members does not change the remaining requirement graph), but E2 must
actually run `cargo metadata --offline` before `--locked` is used everywhere.

### P2-7. `definition.<system>` is system-independent

`§3` exposes `definition.<system>` per system, but the definition (pname,
projectDir, deps, platforms) is host-independent. Minor contract smell.

### P2-8. `mirrors.lock.json` generation is not a pure function

`§10.2` writes a `flake.lock` per mirror that "pins nixpkgs/crane/flake-lib".
Generating it requires network / a lock tool; `mirrors-fresh` then fails on
every monorepo nixpkgs update until all mirrors are regenerated. Fix: pin
mirrors to the monorepo lock by construction (no independent mirror lock) or
accept the churn and document it.

---

## NOTE

- The `base` passthru (`§3`) is not really an "internal leak" — crane's
  `cargoArtifacts` is a public input — but `definition` does not need it.
- `mirrors-fresh` content gate is the highest-value control; the drv-equality
  gate is the right second layer but requires materializing mirrors in CI.
- Platform gating (`§12`) is a genuine improvement over L's unfiltered union
  base; the "host-available member subset" is the right cut.
- The `canonical component manifest` (§9.2) is a real, bounded localizer; it is
  correctly marked optional.

---

## What ECHO gets right

1. **The core lever is real.** Layout-preserving mirror + `builtins.path` yields
   identical filtered source store paths; I verified the mechanism, and the
   union-vs-component distinction is correctly framed (union is a cache hint,
   not semantics).
2. **Keeping L's `-p m` and dropping REWEAVE's union rewrite is the correct
   call** for G10/G11; `research §3.1-3.3` supports it.
3. **`.rs` locality survives** ECHO's changes: crane `73b9805` `mkDummySrc` ->
   `findCargoFiles` + `cleanSourceWith` filters to
   `Cargo.toml`/`Cargo.lock`/`.cargo`, and `cleanCargoToml` keeps
   `[workspace].members`, so `dummySrc`/base is content-addressed on
   manifests/lock (not `.rs`) and `cargoWorkspaceMembersPrePatch` still applies.
   E9 is credible.
4. **`cargoArtifactsBase` as the single builder seam is the right shape**
   (crane's `cargoArtifacts` input), and the two coherent base policies are
   honestly stated, including the 2.05x cost and the standalone/composed
   identity trade-off.
5. **Honest about W10, global root-manifest churn, extraction risk, and the
   non-flat mirror.** The `mirrors-fresh` + drv-equality gates are the right
   controls, and the no-IFD path (path-only `readFile`, no derivation reads)
   looks sound.
