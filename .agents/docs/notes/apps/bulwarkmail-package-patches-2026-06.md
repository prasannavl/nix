# Bulwarkmail Package Patches 2026-06

`pkgs/ext/bulwarkmail` carries repo-owned patches for behavior that upstream
does not expose as configuration yet.

- `client-imip-sending-flag.patch` and `local-geist-fonts.patch` are existing
  package-local behavior patches.
- `server-logout-route.patch` adds `GET`/`POST`/`DELETE` `/api/auth/logout`,
  clears every Bulwarkmail session/refresh/auth-context cookie slot, best-effort
  revokes refresh tokens when the upstream metadata exposes revocation, and
  redirects to `/en/login`.

Keep host or edge-auth logout-chain wiring outside this package. This package
patch only gives callers a stable app-local logout endpoint to chain through.
