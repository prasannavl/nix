# Rust

## Scope

- Apply these rules when editing Rust packages under `pkgs/**`.
- Read `.agents/docs/notes/tooling/cargo-workspace-2026-04.md` before changing
  the root Cargo workspace shape. Preserve destination membership and lock
  policy.

## Current monorepo shape

- The repo currently uses one root virtual Cargo workspace with one root
  `Cargo.lock`.
- Current Rust package Nix builds call `pkg.mkRustDerivation` with `pname`,
  `version`, `projectDir`, and `meta`; the helper builds through `crane` when
  the root flake supplies `pkgs.craneLib`, with a separate dependency artifact
  from `buildDepsOnly` and a final package build that reuses `cargoArtifacts`.
  The fallback path still uses `rustPlatform.buildRustPackage` for standalone
  imports that do not have `pkgs.craneLib`.
- Generated Rust `checks.fmt`, `checks.lint`, and `checks.test` should also be
  explicit crane derivations when `pkgs.craneLib` is available. Formatting uses
  `cargoFmt`; lint and test use `cargoClippy` / `cargoTest` against the same
  dependency artifact as the package build, so CI checks remain separately
  cacheable instead of being opaque overrides of the final package derivation.
- The helper builds a filtered workspace source with the root `Cargo.toml`, root
  `Cargo.lock`, and the selected package directory. During `prePatch`, it
  narrows root `workspace.members` to the selected package plus `deps`, then
  package-scoped cargo commands build one package out of that narrowed
  workspace.
- Narrowed crane workspace builds use the root lockfile for vendoring, then run
  Cargo with `--offline` instead of `--locked` inside the sandbox. Cargo may
  rewrite the temporary build-tree lockfile to match the narrowed workspace, but
  it cannot fetch dependencies outside the vendored set. Repo-root package
  operation commands and non-crane fallback builds stay locked.
- A repository may list exact private Git package sources in `Cargo.lock.nix`
  when a locked non-flake input supplies those sources before sandboxed builds.
  The package must patch every listed source to that exact local input path;
  absent lock entries fail evaluation, and evaluator credentials must never
  enter a derivation or cache output. A package-owned NixOS module that rebuilds
  the package by default must forward the same source input; testing only the
  package output does not prove the host module's package can build offline.
- When a generated service module's default package is reconstructed outside the
  repository overlay, set the live host's `package` option to the composed
  `pkgs.<package>` derivation. This keeps Crane, toolchain, and exact
  lock-source policy attached to the deployed package. Validate that the
  configured host package and root package have the same `drvPath` before
  deployment.
- Keep Rust package `default.nix` files as a single `mkRustDerivation` call when
  possible. Use `enableDevShell`, `extraDevShellPackages`, and `extraPassthru`
  instead of wrapping the result in `wirePassthru` just to add common package
  outputs. If an extra passthru value needs the final package, pass
  `extraPassthru = build: { ... };`; the helper calls it after the base package
  has `sourcePath`.
- Put tools needed by Rust tests in `nativeCheckInputs`; the helper propagates
  them to the main build check, generated `checks.test`, and package operation
  test runner.
- Put tools needed only by Rust formatting or linting in `fmtNativeBuildInputs`
  or `lintNativeBuildInputs`. These flow to both the derivation checks and
  package operation runners. When `enableDevShell = true`, the dev shell is a
  superset of the Rust operation inputs (`rustfmt`, `clippy`, fmt/lint/test
  inputs) plus any `extraDevShellPackages`; shell-only extras do not flow back
  into checks.
- When a Rust crate lives below the package's owning child-flake directory, keep
  `projectDir` pointed at the crate but set `projectPath` to the child-flake
  root. Root lint uses `projectPath` for change ownership and command working
  directory, while builds use `projectDir` for workspace source filtering.
- Native libraries needed by direct Cargo checks must be declared through
  `lintNativeBuildInputs` / `nativeCheckInputs` and any required discovery
  variables such as `PKG_CONFIG_PATH` must be set in `checkEnv`. Dev-shell or
  build-only inputs do not implicitly configure package-operation commands.
- The filtered workspace source composes the package/dependency source boundary
  with the repo's `.gitignore`; keep generated Rust build artifacts ignored
  there instead of duplicating source-cleaning exclusions in Nix.
- Crane builds consume a materialized `cargo-workspace-source` derivation whose
  input is already filtered to the selected package plus explicit `deps`.
- The materialization derivation must fail if `.git`, `target`, or `dist`
  directories reach the filtered source. This is a hard guard against copying
  generated or VCS state into the Nix store before crane sees the source.
- Patched external Rust packages under `pkgs/ext` should use the same split when
  possible: build unpatched dependencies with `craneLib.buildDepsOnly`, then
  apply local patches only in the final `craneLib.buildPackage` derivation. That
  keeps iterative patch edits from recompiling the full dependency graph.
- The shared root `Cargo.lock` means a cold crane vendoring/dependency build can
  still enumerate crates for the full lockfile. The important incremental
  boundary is that package source changes should invalidate only the final
  package derivation, not the dependency artifact.
- Do not casually reintroduce package-local Rust lockfiles or remove
  `{ workspace = true }` dependency declarations from existing packages. That is
  a future migration step, not the current build contract.
- If a package depends on a local shared workspace crate, add that crate's
  directory to `deps` on the consuming `mkRustDerivation` or `mkTrunkProject`
  call. This keeps changes to the shared crate in the consumer's source hash
  without letting unrelated repo files invalidate every Rust build.

## Toolchain and cache foundation

- `toolchain = null` retains the effective nixpkgs/Crane compiler. Immutable
  provider contracts are explicit and lazy; unsupported custom Nix-cross
  contracts fail closed. Fenix is preferred when available; oxalica toolchain
  files and pre-resolved derivations remain supported.
- Composition policy is repository-owned. Preserve existing admission/defaults,
  package-local features and native/Tauri/WASM requirements. Shared helper
  support does not authorize Cargo manifest normalization or a peer-wide union.
- Real layers require matching producer compiler identity. Opaque supplied
  builds are not relabeled. Rustup and guessed artifact-message unit graphs are
  not qualified production toolchains/producers.
- See the [foundation contract](../design-patterns/rust-foundation.md) and
  [main handoff](../notes/tooling/rust-foundation-main-handoff-2026-10-12.md)
  for admission rules, qualified source pins and validation limits. The newer
  `Cargo.lock.nix` policy is unsupported by optional closure/base/mirror routes;
  the ordinary package route preserves its source replacement. This repository
  does not add a root `Cargo.lock.nix` policy as part of this shared port.

## New Rust package guidance

- Add new Rust packages to the root `Cargo.toml` `workspace.members` list.
- Refresh the root `Cargo.lock` from the repo root.
- Prefer shared dependency versions in `[workspace.dependencies]`.
- In package manifests, use `{ workspace = true }` for shared dependency
  versions and declare package-specific feature needs locally.
- Keep Nix package definitions ready for dual source modes by accepting source
  and lockfile inputs from the caller instead of discovering them with fixed
  upward paths.

## Future isolated mode

- Standalone-capable Rust package flakes will need a local Rust source boundary
  and a local `Cargo.lock`.
- A standalone-capable package manifest cannot rely only on
  `{ workspace = true }` unless the standalone flake generates or supplies a
  containing workspace manifest.
- The future dual-mode Nix shape should be:
  - monorepo mode receives repo root `src`, root `Cargo.lock`, and `projectDir`;
  - isolated mode receives package-local `src`, package-local `Cargo.lock`, and
    no `projectDir`.
- Isolated mode may rebuild dependencies less efficiently. That is acceptable if
  the package still builds and develops without requiring the monorepo.

## Validation

- For current packages, validate root integration with root-flake builds when
  the tree has untracked files.
- Child-flake validation can remain secondary until the helper import and Cargo
  source boundaries are split.
