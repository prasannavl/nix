# Podman Compose Start-State Verification (2026-03)

## Context

`lib/podman.nix` already kept generated compose units alive with
`podman compose wait`, but that still allowed a partial-start failure mode:
`podman compose up -d` could leave one or more containers in `Created` while
the user service stayed green because `wait` only attached to the containers
that were actually running.

The concrete trigger was `immich` on `pvl-x2`: the deploy completed cleanly,
`pvl-immich.service` stayed active, but `immich_server` and `immich_redis`
were left in `Created` after a transient runtime failure during container
startup.

## Decision

- After every generated compose `up -d`, verify the full compose state before
  handing supervision over to `podman compose wait`.
- Fail the service if any compose container is left in a non-running state,
  except for clean `exited` containers with exit code `0`.

## Implementation

- `lib/podman.nix` now generates a `verify` script per compose instance.
- The script runs `podman compose ps --format json` and rejects containers that
  are:
  - `Created`
  - `Configured`
  - `Exited` with a non-zero code
  - or any other non-running state
- `ExecStart` and `ExecReload` both call the verify script immediately after
  `podman compose up -d --remove-orphans`.

## Operational Effect

- Partial-start failures now fail the generated user service instead of being
  hidden behind a still-running `podman compose wait` process.
- Deploy-time reconciler runs and plain user-service restarts surface the
  broken container names and states directly in the journal.
