# Bulwarkmail Package Patches 2026-06

`pkgs/ext/bulwarkmail` carries repo-owned patches for behavior that upstream
does not expose as configuration yet.

- `calendar-organizer-attendee-shape.patch` and `local-geist-fonts.patch` are
  existing package-local behavior patches.
- `server-logout-route.patch` adds `GET`/`POST`/`DELETE` `/api/auth/logout`,
  clears every Bulwarkmail session/refresh/auth-context cookie slot, best-effort
  revokes refresh tokens when the upstream metadata exposes revocation, and
  redirects to `/en/login`.

Keep host or edge-auth logout-chain wiring outside this package. This package
patch only gives callers a stable app-local logout endpoint to chain through.

## npm dependency fetch concurrency

Bulwarkmail's large lockfile can make `prefetch-npm-deps` issue enough parallel
HTTP/2 requests to trigger intermittent curl error 92 failures on different npm
tarballs. The source incident reproduced this twice at normal builder
parallelism and then completed the same fixed-output derivation with one fetch
worker, separating concurrency from package URL or registry reachability.

The package therefore defines `fetchNpmDeps` explicitly and sets
`NIX_BUILD_CORES = "1"` only on that fixed-output dependency fetch. The
`buildNpmPackage` application build consumes the resulting `npmDeps` output and
retains normal builder parallelism.

Keep `src`, `patches`, and `postPatch` shared by `fetchNpmDeps` and
`buildNpmPackage`. Both phases must see the same effective lockfile and source
tree, or the dependency cache can diverge from the application build.
