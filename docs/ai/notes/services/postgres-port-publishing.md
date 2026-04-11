# Postgres Port Publishing

## Scope

Durable note for the `hosts/pvl-x2/services/postgres.nix` compose wiring and the
host-port publishing failure observed on April 12, 2026.

## Finding

- The Postgres container `postgres_postgres_1` was healthy and accepted local
  connections inside the container.
- The user-facing SSH tunnel targeted `pvl-x2:127.0.0.1:5432`, but nothing on
  `pvl-x2` was actually listening on that host port.
- `podman ps` and `podman port` reported `127.0.0.1:5432->5432/tcp`, but the
  generated `pod_postgres` pod did not expose an infra-level listener for that
  port.
- The result was a misleading local error on the tunneled client: the SSH
  forward accepted the TCP connection on the local machine and then closed it
  because the remote target port was unavailable.

## Decision

- `services.podmanCompose.<stack>.instances.<name>.composeArgs` is the canonical
  escape hatch for instance-specific `podman compose` CLI flags.
- Keep the compose-args plumbing in the shared module so instance-scoped compose
  behavior can be adjusted when a runtime issue needs a narrow workaround.
- Do not set `composeArgs` for `hosts/pvl-x2/services/postgres.nix` by default.
  The observed failure was transient, and a normal service restart restored
  pod-based publishing correctly.

## Rationale

- The failure was not caused by PostgreSQL startup or schema initialization.
- The failure was in Podman Compose's pod-based publishing path for this stack.
- A later plain restart recreated the pod, network, and `rootlessport` listener
  successfully, so the repo should not force a behavioral change for Postgres
  without evidence that the issue is durable.
- Keeping the generic escape hatch still gives a narrow fallback if the problem
  recurs.
