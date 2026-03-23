# Service Module Relocation

- User-directed repo layout change: move `lib/nginx` to `lib/services/nginx` and
  `lib/tunnels` to `lib/services/tunnels`.
- Update host imports to reference the new service-module paths so the move is
  behavior-preserving.
- Keep `podman`, `systemd-user-manager`, and other cross-cutting modules at the
  top-level `lib/`; this relocation applies only to service-specific helpers.
