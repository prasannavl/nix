# Gap3 Porting Phases 2026-05

## Scope

Tracks the staged port of shared changes from the `gap3` repo into this repo so
each reviewable phase stays small and explicit.

## Phase plan

- Phase 1: `nixbot` local flake-ref cleanup plus Podman compose journal-noise
  reduction.
- Phase 2: nginx shared proxy enhancements: `upstreamTlsName` and
  `rootRedirect`.
- Phase 3: Rust package-helper modernization: direct helper builds, helper
  dev-shell wiring, and split Rust check inputs.
- Phase 4: `service-module` follow-up hardening for package/source-path based
  identity wiring once the Rust helper shape is in place.

## Current decision

- Start with the lowest-risk shared infra changes first.
- Keep phase boundaries small enough that each phase can be reviewed and merged
  independently.

## Phase 1 details

- Replace explicit local `path:.#...` flake refs in `nixbot` with `.#...`.
- Redirect normal `podman compose` lifecycle stderr to stdout in the helper so
  journald does not mark routine container output as priority `err`.

## Phase 2 details

- Add `upstreamTlsName` so nginx can send explicit SNI independently of the
  upstream `Host` header.
- Add `rootRedirect` so a derived root proxy vhost can redirect exact `/`
  requests before the normal catch-all proxy location.

## Phase 3 details

- Extend `mkRustDerivation` so Rust packages can build directly from helper
  inputs instead of hand-building and wrapping a separate derivation.
- Add helper-level `enableDevShell`, function-valued `extraPassthru`, and split
  Rust check inputs for fmt, lint, and test flows.
- Bring in the repo-root Cargo workspace shape: explicit root `members`, root
  `Cargo.lock`, `projectDir`-driven helper builds, filtered workspace sources,
  and the `prePatch` workspace-members rewrite.
- Migrate the local `hello-rust` example to the workspace helper style so the
  upstream contract is exercised in-tree.

## Phase 4 details

- Harden `service-module` bound-module resolution to prefer
  `build.passthru.sourcePath` before falling back to `build.src`.
- Harden client-identity secret modules to resolve the package from
  `sourcePath`, so age-secret wiring follows the configured package source
  rather than brittle derivation-object equality.

## Phase 5 details

- Port the broader `service-module` identity API: unified `mkIdentity*` helpers,
  external-service identity support, and generic secret-owner defaults.
- Add the isolated Rust example package so workspace and non-workspace Rust
  flows both exist in-tree.
- Port `mkTrunkProject` and the shared WASM bootstrap hook so Rust/Trunk web
  packages can reuse the same CSP-safe build and dev-shell contract as `gap3`.
- Finish the remaining helper parity sweep:
  - add repo-default NATS, PostgreSQL, and vmstack secret-base paths in
    `stack.nix`
  - restore the upstream Rust check wiring for `preBuildPhase`,
    `nativeCheckInputs`, and resolved fmt cargo args
