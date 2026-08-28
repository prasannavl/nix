# Top-Level Cargo Workspace (2026-04)

The repo has a root virtual Cargo workspace in `Cargo.toml` so editor tooling
can discover all Rust packages from the repo root. This is primarily for VS Code
and rust-analyzer: opening the repo root should now expose a single workspace
graph instead of requiring a separate editor window per package.

The workspace explicitly lists every Rust package under `pkgs/**/Cargo.toml` and
uses Cargo resolver `3`, matching the repo's edition 2024 package while keeping
edition 2021 packages compatible.

Package-level Nix builds pass `pname`, `version`, `projectDir`, and `meta` to
`pkg.mkRustDerivation`. The root flake supplies `pkgs.craneLib`, so normal Rust
packages build through `crane`: `buildDepsOnly` creates the dependency artifact,
and the final package build reuses it via `cargoArtifacts`. The helper still has
a `rustPlatform.buildRustPackage` fallback for standalone imports that do not
have `pkgs.craneLib`.

The generated Rust check derivations follow the same model. `checks.fmt` uses
`craneLib.cargoFmt`, while `checks.lint` and `checks.test` use
`craneLib.cargoClippy` and `craneLib.cargoTest` with the shared `cargoArtifacts`
dependency output. This keeps formatting, linting, testing, and the final
package build separately cacheable. The generated `checks.test` derivation
forces `doCheck = true` after package build attributes are merged; a final
package may deliberately set `doCheck = false` without silently turning its
separate Cargo test gate into a no-op.

The helper uses a filtered workspace source containing the root `Cargo.toml`,
root `Cargo.lock`, and the selected package directory. During `prePatch`, the
helper narrows root `workspace.members` to the selected package plus `deps`.
Package-scoped cargo commands still build one package out of the workspace,
while unrelated repo files no longer invalidate every Rust package derivation.
Package-local Rust lockfiles were removed so dependency versions have a single
source of truth.

For narrowed crane workspace builds, the root `Cargo.lock` remains the vendoring
input, but the sandboxed Cargo invocation uses `--offline` instead of
`--locked`. Cargo 1.91 treats the full root lockfile as needing an update after
`workspace.members` has been narrowed, because unrelated workspace packages are
pruned from the temporary build-tree lockfile. Offline mode allows that local
lockfile rewrite without permitting network access; any dependency missing from
the root lockfile/vendor set still fails. Repo-root package operation commands
and non-crane fallback builds stay locked.

For ordinary repo-root workspace packages, prefer passing `projectDir` and
letting the helper supply the repo-root `src` default. Do not redundantly hard
code `src = ../../..` on top of `projectDir` unless a package genuinely needs a
different source contract; that extra explicit root-store path can drift away
from the helper's filtered-source path and reintroduce brittle `...-source`
references during flake evaluation.

The filtered source composes this selected-directory boundary with the repo's
`.gitignore`, so build outputs such as `target/` and `dist/` stay out of Nix
source hashes without duplicating ignore patterns in Nix.

For crane builds, the helper materializes that filtered source through a small
`cargo-workspace-source` derivation before handing it to the package build. The
materialization derivation receives the already-filtered source, so the
invalidation boundary remains the selected package plus explicit `deps`; the
extra derivation exists only to give crane a concrete source output to consume.
The materialization derivation fails before copying if `.git`, `target`, or
`dist` directories ever pass the filter, which keeps ignored generated artifacts
out of the store even if a future helper edit weakens the selected-directory
logic.

Because the repo intentionally keeps one root `Cargo.lock`, a cold crane
vendoring/dependency build can still enumerate crates from the full lockfile.
That is not the same as rebuilding every package from source: the durable
incremental boundary is that ordinary source edits to a selected package
invalidate the final package derivation while keeping the dependency artifact
reusable until manifests, the lockfile, build inputs, or explicit `deps` change.

Patched external Rust packages should keep local patches out of the dependency
artifact when those patches do not change Cargo manifests.
`pkgs/ext/stalwart-server` is the current example: `craneLib.buildDepsOnly`
compiles the upstream dependency graph, and the local Stalwart patches are
applied only in the final `craneLib.buildPackage` derivation. Patch iteration
should therefore reuse the dependency artifact instead of rebuilding the full
upstream project graph.

Derivation-backed external sources must never be inspected during evaluation. Do
not use `builtins.pathExists`, `builtins.readFile`, or Crane's implicit source
discovery against a `fetchFromGitHub` result. When such a package supplies
`cargoHash`, `mkCraneRustPackage` creates the fixed-output vendor tree with
`rustPlatform.fetchCargoVendor`, passes it as `cargoDeps`, installs its registry
and Git-source configuration with `rustPlatform.cargoSetupHook`, and sets
`cargoVendorDir = null` so Crane does not try to vendor the fetched source
again. Its dependency build uses the fetched source as an explicit `dummySrc`,
which makes source realization a normal build dependency instead of IFD. Keep
this boundary intact for external packages with Git dependencies as well as
registry-only lockfiles.

When a helper builds from a filtered workspace source, do not keep a raw
`cargoLock.lockFile` path pointed at that filtered source. In this repo, prefer
`cargoLock.lockFileContents = builtins.readFile (src + "/Cargo.lock")` for
helper-generated workspace defaults, while the actual package `src` still uses
the filtered workspace source. That keeps the canonical root workspace lockfile
contents without retaining a brittle filtered-source store-path reference, which
can otherwise show up later as `path '...-source' is not valid` when Nix tries
to realize `Cargo.lock`.

When a package uses a local shared workspace crate, list that crate directory in
the consuming package's `deps`. That makes the dependency explicit in the Nix
source boundary: changes to the shared crate rebuild its consumers, but changes
to unrelated packages or repo tooling do not. Use the same `deps` spelling for
local repo project dependencies in other language helpers as those source
boundaries are added.

This is the current build contract. Do not break it when preparing packages for
future isolated child-flake builds.

When adding a Rust package, add its directory to the root `Cargo.toml`
`workspace.members` list and refresh the root `Cargo.lock` with Cargo from the
repo root. Put shared dependency versions in `[workspace.dependencies]`; member
manifests should normally use `{ workspace = true }` and declare only their
feature needs.

For future isolated-flake work, keep monorepo mode efficient while making Nix
package definitions ready to receive `src`, `Cargo.lock`, and `projectDir` from
the caller.
