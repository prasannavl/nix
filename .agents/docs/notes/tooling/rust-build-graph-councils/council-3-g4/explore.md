# G4 explorer facts — Rust build-graph invalidation locality

Read-only exploration. Method:

- `cargo metadata --offline --locked` (exit 0) -> `tmp/design-g4/metadata.json`
- `nix eval` of
  `packages.x86_64-linux.<m>.passthru.{sharedDepsBase,memberLayer}` and
  `.drvPath`
- raw `.drv` + `nix-store --query --references` inspection

All line numbers: `lib/flake/pkg-helper.nix` unless noted.

## 1. Exact derivation-input chain of the current base

Call chain:

- `mkSharedRustDepsBase` (:179-196)
  - `dummySrc = craneLib.mkDummySrc { src = source; }` (:190)
  - `pname = "abird-rust-workspace"`, `version = "0.1.0"` (:191-192)
  - `cargoExtraArgs = "--offline --workspace"` (:193)
  - `inherit cargoLockContents cargoVendorDir` (:194)
  - -> `craneLib.buildDepsOnly` with `cargoArtifacts = null` (crane
    `lib/buildDepsOnly.nix:64`), `doCheck = true` default
- `source` is `workspaceSource` (:2243-2244) = `mkRustWorkspaceSource pkgs src`
  (:167-172)
- `mkRustWorkspaceSource` ->
  `mkWorkspaceSourcePath { selectedDirs = rustWorkspaceMembers src }` (:167-172)
- `rustWorkspaceMembers` (:142-160) reads root `Cargo.toml`
  `[workspace].members` at eval time; refuses globs (returns `[]`).

Measured base derivation (all 5 root members eval to the **same** drv):
`/nix/store/wp01m3cy7j5skpm36dzx0lw63h4znfyg-abird-rust-workspace-deps-0.1.0.drv`
output
`/nix/store/qb4r32albhajflyqv972402byahw2546-abird-rust-workspace-deps-0.1.0`

Direct/t transitive inputs from the `.drv` reference set:

- `cargo-workspace-source.drv` `/nix/store/vhzdi9rx43p6rwvhygzk2khqmrzicm5x-...`
  (the **dummy** source)
  - references exactly 6 `Cargo.toml.drv` (root + 5 members) + `dummy.rs.drv` +
    `cleaned-mkDummySrc`
  - `cleaned-mkDummySrc` `/nix/store/0rm9y4qyn68md7r3s6dmlydd0gkmbqlg-...`
    contains **only `Cargo.lock`** (no `.cargo` dir exists in this repo)
  - each `Cargo.toml.drv` is `crane-json2toml` over `cleanCargoToml` output
    (crane `filters/cargoTomlConservative.nix`, the default filter)
- `Cargo.lock.drv` `/nix/store/ikg54zm3bfdhy0cfbxx5kb4gbn6bdl9p-Cargo.lock.drv`
  (writeText of full lock)
- `vendor-cargo-deps.drv` `/nix/store/06sigrby9ahj6a9c1hz5safwfswh67md-...`
  (keyed on full lock, see §6)
- toolchain/hooks: cargo-1.95.0, rustc-wrapper, stdenv, bash, zstd, rsync,
  replaceCargoLockHook, configureCargoCommonVarsHook,
  configureCargoVendoredDepsHook, inheritCargoArtifactsHook,
  installCargoArtifactsHook.

Manifest content that **can** change the base drv (retained by cleanCargoToml,
verified by dumping each `Cargo.toml.drv` `contents`):

- root: entire `[workspace.dependencies]` map + `members` + `resolver`
- members: `[dependencies]`/`[dev-dependencies]`/`[build-dependencies]` entries,
  `features`, `workspace = true` markers, `[features]`, `[[bin]] {name,path}`,
  `[package] {name,version,edition,build}`
- lock contents; `.cargo/config*` if present
- e.g. `abird-host-manager` cleaned manifest = only `dependencies` +
  `package{build,edition,name,version}`; `nats-wrecking-ball` keeps all three
  `[[bin]]` paths.

What the base drv does **NOT** depend on (confirmed by `.drv` refs / dummy
filtering):

- any `*.rs` content (replaced by `dummy.rs.drv`)
- member `default.nix` or any Nix file
- non-manifest files under member dirs (the full `workspaceSource` path is not
  an input; only the re-filtered dummy is)
- per-member build attrs: `nativeBuildInputs`, `checkEnv`, `buildAttrs`,
  `pname/version`, `cargoExtraArgs` (mkSharedRustDepsBase takes none of these)
- removed manifest metadata: `description`, `license`, `authors`, `repository`,
  `[lints]`, target `required-features` (conservative filter).

## 2. Member layers and what changes when the base changes

`memberLayer` (:2400-2411) =
`craneLib.cargoBuild (craneCommonAttrs // { cargoArtifacts = dependencyArtifacts; cargoExtraArgs = shellWords resolvedCraneBuildCargoArgs; doInstallCargoArtifacts = true; })`.

Inputs:

- `craneCommonAttrs` = `commonAttrs` (`src = buildSrc`,
  `prePatch = buildPrePatch`, `pname/version/meta/nativeCheckInputs` +
  `buildArgs`/`buildAttrs`) + `resolvedCraneCargoLockAttrs` + `cargoVendorDir`
- `buildSrc` (:2261-2265) =
  `mkCargoWorkspaceSource { src; projectDir; deps = resolvedDeps; }` — keeps
  that member's dir **plus every internal path-dep dir** in full
- `buildPrePatch` (:2281-2287) = `cargoWorkspacePrePatch` rewrites root
  `members` to `[projectDir] ++ deps`
- `dependencyArtifacts` (:2387-2398):
  - no internal deps -> `prefixNode` = `sharedDepsBase`
  - exactly one -> that dep's `passthru.memberLayer`
  - =2 -> `mkCargoArtifactsJoin` (definition :198-217; **no call in this repo**,
    > fan-in never happens)
- `cargoExtraArgs` = `resolvedCraneWorkspaceCargoArgs resolvedBuildCargoArgs` =>
  `["--offline","-p",pname]` (`defaultCargoPackageArgs` :33-36,
  `craneWorkspaceCargoArgs` :37-40)

Measured (base drv = `wp01m3...`):

- `abird-host-agent` layer `sbka3y4...` inputs shared base directly
- `example-hello-rust` layer `ggv0n8v...` inputs shared base directly
- `abird-host-manager` layer `522x0fv...` inputs `abird-host-agent` layer
  `sbka3y4...` (which inputs the base)
- `nats-http-bridge` layer `rw6id89...`, `nats-wrecking-ball` layer `gqikmns...`
  likewise chain to the base.

Base-change propagation (all drvs whose store path changes):

- base `wp01m3...` changes -> all **5** `memberLayer` drvs change (dependency
  chain or direct `cargoArtifacts`) -> each member's `build` (`buildPackage`
  with `cargoArtifacts = memberLayer`, :2426-2437) and
  `checks.lint`/`checks.test` (`mkCraneCheckAttrs`, :2416-2424) change.
- `checks.fmt` uses `craneCommonAttrs` only (:2452-2458), so it does **not**
  track the base.
- `hello-rust` has zero externals, yet its layer still tracks the base because
  `prefixNode = sharedDepsBase` unconditionally.

## 3. Per-member external closures (measured)

Cargo-accurate "base-relevant" closure = transitive normal+build deps plus each
member's own direct dev-deps closure (matches `--workspace --all-targets`).
Counts are distinct registry crate names.

| member             | directly-declared externals (normal+build)                                                                                      | dev-only | closure (names)                          |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------- | -------- | ---------------------------------------- |
| hello-rust         | (none)                                                                                                                          | -        | 0                                        |
| nats-http-bridge   | anyhow, async-nats, bytes, clap, futures-util, reqwest, serde, serde_yaml, tokio, tracing, tracing-subscriber                   | -        | 221                                      |
| abird-host-agent   | anyhow, clap, libc, serde, serde_json, shlex                                                                                    | tempfile | 63 (31 without the tempfile dev closure) |
| abird-host-manager | age, anyhow, base64, clap, humantime, libc, serde, serde_json, sha2, ssh-key, tempfile, uuid, zeroize (+ path abird-host-agent) | -        | 220                                      |
| nats-wrecking-ball | anyhow, async-nats, bytes, clap, futures-util, humantime, rand, serde, tokio, tracing, tracing-subscriber                       | -        | 208                                      |

- union of names: **333** = exactly all registry names in the lock (367 registry
  package IDs; 30 names have >1 version, 4 have 3).
- union of package IDs: **367 registry + 5 path = 372** = the entire lock.
- sum of member closures = 712; union/avg = ~2.34x by name (all five), ~1.87x
  over the 4 real members.
- If dev edges of external crates are traversed (cargo would not), union is 367
  names (agent 65), but the ID union is unchanged.

Overlap structure (base-relevant, crate names):

- all 4 real members share **45**:
  anstream/anstyle*/anyhow/bitflags/cfg-if/clap*/colorchoice/equivalent/errno/getrandom/hashbrown/heck/indexmap/is_terminal_polyfill/itoa/libc/log/memchr/once_cell/polyfill/proc-macro2/quote/r-efi/rand_core/semver/serde*/serde_json/shlex/strsim/syn/unicode-ident/utf8parse/wasip2/windows-link/windows-sys/wit-bindgen/zmij
- shared by >=2 members: **213** (45 in all 4, 76 in exactly 3, 92 in exactly
  2). `hello-rust` shares none.
- pairwise: bridge&agent 45, bridge&manager 108, bridge&wrecking 192,
  agent&manager 63, agent&wrecking 59, manager&wrecking 123.
- exclusive-to-a-pair (shared by exactly those two): bridge&wrecking 85
  (async-nats/tokio/hyper/rustls stack), agent&manager 4 (fastrand,
  linux-raw-sys, rustix, tempfile), manager&wrecking 2 (chacha20, humantime),
  bridge&manager 1 (rustc-hash), bridge&agent 0, agent&wrecking 0.
- unique-only (in exactly one): bridge 28 (reqwest/hyper/serde_yaml/tower...),
  manager 92 (age/crypto/i18n/ssh-key...), agent 0, wrecking 0, hello 0.

## 4. Path-connected components (internal path deps)

Only one edge: `abird-host-manager` -> `abird-host-agent`
(`[dependencies] abird-host-agent = { path = "../abird-host-agent" }`;
`deps = ["pkgs/tools/abird-host-agent"]`,
`internalDeps = optional (abirdHostAgent != null) abirdHostAgent`, manifest
`pkgs/manifest.nix:5-8`). Components: `{abird-host-agent, abird-host-manager}`
and three singletons `{hello-rust}`, `{nats-http-bridge}`,
`{nats-wrecking-ball}`. There is no other path edge and no fan-in (so
`mkCargoArtifactsJoin` is unused).

## 5. Lock facts

- `Cargo.lock`: `version = 4`, **372** `[[package]]` entries.
- **367 registry** entries (crates.io index) + **5 path/workspace** entries (the
  5 members, `source` absent). No git entries, no `[patch]`.
- 338 distinct names; 30 names have 2-3 versions
  (getrandom/rand/rand_core/windows-sys have 3).
- Every registry package ID is reachable from the union of the 5 members'
  base-relevant closures (no orphan lock entries).
- A closure-subset lock is self-contained: registry entries carry their own
  `dependencies` by name; path entries must retain their path deps (manager's
  subset must include the `abird-host-agent` entry). Shared transitive names
  that any multi-member subset must keep are the 45 shared by all 4 real members
  and the 213 shared by >=2.

## 6. Vendor derivation

- `craneCargoVendorDir = craneLib.vendorCargoDeps resolvedCraneCargoLockAttrs`
  (:2302-2304); `resolvedCraneCargoLockAttrs` (:2273-2280) =
  `{ cargoLockContents = readFile (src + "/Cargo.lock"); }` when
  `cargoLock == null` (the normal case). One vendor drv is computed per
  `mkRustDerivation` and shared by both the base and the member build.
- crane `vendorCargoDeps.nix` ->
  `vendorMultipleCargoDeps { cargoLockParsedList = [ (fromTOML cargoLockContents) ]; ... }`:
  `lockPackages` is the **whole** lock's package list (trimmed to
  name/version/source/checksum). Output is one `vendor-cargo-deps` dir +
  `config.toml`.
- Therefore today the vendor dir is keyed on the **entire** lock, not a subset.
  It can accept a subset `cargoLockContents` (seam is the argument), but the
  caller always passes the whole root lock.

## 7. Existing subset-base support in current code

Present:

- `mkWorkspaceSourcePath` (:67-100): fully generic `selectedDirs` subset source
  filter; used by the base with `rustWorkspaceMembers` but is not fixed to the
  whole workspace.
- `mkRustWorkspaceSource` (:167-172): convenience wrapper only; a subset caller
  could call `mkWorkspaceSourcePath` directly.
- `mkSharedRustDepsBase` (:179-196): no hard-coded workspace; takes `source`,
  `cargoLockContents`, `cargoVendorDir` as parameters -> this is the
  parameterization seam. Currently called once per package with whole-workspace
  values (:2348-2363).
- `cargoWorkspacePrePatch` (:235-259): rewrites root `members` to a selected
  `[projectDir] ++ deps`; applied to member builds (`buildPrePatch`, :2281-2287)
  but **not** to the base's dummy source.
- `rustWorkspaceMembers` (:142-160) / `isWorkspaceMember` (:161-164): eval-time
  member list; `isWorkspaceMember` gates `workspaceMode` (:2235-2241).
- `useWorkspaceDeps` (:2132) per-package opt-out to the legacy per-package
  `buildDepsOnly` (rollback path); `packageCargoArtifacts` (:2334-2346) and
  `prefixNode` fallback.

Absent (only in design docs, not code):
`component`/`componentMode`/`componentDirs`, `shardBase`, `depsBase`,
`mirrorUnit`, a `base` argument to `mkRustDerivation`, or any
per-member/per-signature base call. `grep` over `lib/` finds none;
`dual-mode-rust-build-graph-2026-09.md` / `design-f-build-graph-2026-09.md`
describe them as unbuilt proposals.
