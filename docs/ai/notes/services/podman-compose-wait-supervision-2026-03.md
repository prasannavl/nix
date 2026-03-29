# Podman Compose Runtime Supervision (2026-03)

## Scope

Adjust `lib/podman.nix` so generated compose units are not `Type=oneshot`
wrappers around detached `podman compose up -d`, and keep the later
provider-compatibility follow-up in the same record.

## Decision

- The main generated compose unit now uses a long-running service model:
  - `ExecStart` runs a store script that stages runtime files, changes into the
    working directory, performs `podman compose up -d --remove-orphans`,
    verifies the resulting container states, signals readiness to systemd, and
    then `exec`s a monitor loop.
  - The monitor loop polls `podman compose ps --format json` and fails the unit
    if any managed container falls into a bad non-running state.
  - `ExecStop` runs a store script that changes into the working directory when
    available and performs `podman compose down`.
- The generated unit now uses `Type=notify` with `Restart=on-failure` instead of
  `Type=oneshot` plus `RemainAfterExit=true`.
- Lifecycle tag actions remain separate oneshot user units; only the main stack
  unit changes supervision model.

## Why

- `Type=oneshot` only tracks whether the initial detached compose command
  succeeded. If containers later stop or crash, systemd still shows the unit as
  active because the service already exited successfully.
- A long-running monitor gives systemd a real runtime state to supervise and a
  failure signal it can restart.
- `Type=notify` prevents deploy-time callers from treating the unit as started
  before the compose startup verification has actually passed.
- Using explicit start/stop scripts that `cd` into the staged workdir keeps
  relative compose behavior correct even when the working directory did not
  exist before the first start.
- The external `podman-compose` provider on `pvl-x2` does not implement
  `podman compose wait`, so supervision had to move to a provider-agnostic
  monitor loop instead of the original wait-based design.

## Constraints

- This improves supervision for the current external `podman-compose` provider
  model without forcing an immediate migration to Quadlet.
- It still does not make systemd directly own each individual container unit;
  for per-container native systemd ownership, Quadlet remains the stronger
  long-term architecture.
