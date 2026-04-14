# Package User Services for `gap3` (2026-04)

## Scope

Move the `pkgs/srv/*` package-owned services onto the existing
`systemd-user-manager` path so they restart under the same user-manager
reconcile flow as the rootless Podman stack on `gap3-rivendell`.

## Decisions

- `stack.srv.mkServicesModule` now defaults through `defaultUser = "gap3"`, so
  package-owned services in the gap3 stack land under
  `userServices.gap3.<name>.*` unless a call overrides `user`.
- The generated runtime stays a `systemd.user.services.<unit>` unit plus a
  matching `services.systemdUserManager.instances.<name>` registration, so
  deploy-time restart orchestration stays inside the existing dispatcher and
  reconciler machinery.
- The underlying `service-module.nix` factory still defaults
  `defaultUser = "root"`, so direct callers outside `stack.nix` continue to get
  system services unless they opt into a non-root user.
- Generated user unit names default to `gap3-<service-name>`, for example
  `gap3-srv-ingest.service`.
- `mkPostgresClientService` and `mkNatsClientService` now accept direct
  systemd-style unit wiring fields such as `after`, `before`, `wants`,
  `requires`, and `wantedBy`.
- Package-owned modules and host config should prefer those direct fields over a
  repo-specific dependency abstraction.

## Applied wiring

- `pkgs/srv/ingest`
- `pkgs/srv/llm`
- `pkgs/srv/trading-api`
- `pkgs/srv/trading-processor`
- `pkgs/srv/trading-transformer-excel`

All five now use plain `srv.mkServicesModule { ... }`, with the target user
coming from the stack-level `defaultUser`.

Their service identities are also staged with `secretOwner = "gap3"` and
`secretGroup = "gap3"` so the rootless user services can read their client
certificates and keys.

That ownership is now the stack default for service identities, so package
modules should normally use plain `srv.mkServiceIdentity {}` unless they need a
real override.

The current package defaults are:

- NATS clients: `after = ["gap3-nats.service"]`
- Postgres clients: `after = ["gap3-postgres.service"]`

These are ordering hints only. Package services are expected to tolerate the
dependency being absent or unhealthy and stay alive while retrying at the
application layer, rather than taking a hard `Requires=` edge on infra units.

## Host API

Enable package services from the host with:

```nix
userServices.gap3 = {
  srv-ingest.enable = true;
  srv-llm.enable = true;
};
```

## Current limitation

- The current stack-level defaults assume the canonical infra unit names
  `gap3-postgres.service` and `gap3-nats.service`.
- If a future stack wants different infra names, override the relevant
  client-helper `after` values in that stack instead of relying on the gap3
  defaults.
