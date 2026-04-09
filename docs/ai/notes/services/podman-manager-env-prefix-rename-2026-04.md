# Nix podman compose env prefix rename

- Date: 2026-04-09
- Scope: `lib/podman-compose/default.nix`, `lib/podman-compose/helper.sh`

## Decision

- Rename wrapper-only environment variables from `PODMAN_COMPOSE_*` to
  `NIX_PODMAN_COMPOSE_*`.

## Why

- The repo's podman-compose helper exported `PODMAN_COMPOSE_METADATA` and
  `PODMAN_COMPOSE_SERVICE_NAME` into the systemd unit environment.
- The helper then invoked `podman compose`, whose compose implementation scans
  `PODMAN_COMPOSE_*` as its own configuration namespace.
- That caused repeated warnings in multiple services about unsupported
  `metadata` and `service_name` keys.

## Rule

- Wrapper-private environment variables must not reuse upstream tool
  configuration prefixes when those variables are inherited by subprocesses.
- For the podman compose wrapper, use the `NIX_PODMAN_COMPOSE_*` namespace for
  helper-owned state.
