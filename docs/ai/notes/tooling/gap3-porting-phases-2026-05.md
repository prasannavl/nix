# Gap3 Porting Phases 2026-05

## Scope

Tracks the staged port of shared changes from the `gap3` repo into this repo so
each reviewable phase stays small and explicit.

## Phase plan

- Phase 1: `nixbot` local flake-ref cleanup plus Podman compose journal-noise
  reduction.
- Phase 2: nginx shared proxy enhancements: `upstreamTlsName` and
  `rootRedirect`.
- Phase 3: Rust package-helper hardening: filtered workspace source handling,
  lockfile handling, and helper eval fixes.
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
