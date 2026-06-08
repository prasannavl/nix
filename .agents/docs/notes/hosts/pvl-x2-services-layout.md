# PVL-X2 Services Layout

## Scope

Durable note for the `hosts/pvl-x2` service-module layout.

## Decision

- Host service wiring now lives under `hosts/pvl-x2/services/`.
- `hosts/pvl-x2/services/default.nix` is the aggregation entrypoint for the
  host's service modules.
- Shared compose stack defaults live in `hosts/pvl-x2/services/default.nix`.
- Compose-backed services keep service-local assets together under
  `hosts/pvl-x2/services/<name>/`, with `default.nix` plus colocated compose
  files.
- Keep one module per service when the service has distinct compose wiring or
  host-facing secrets.

## Rationale

- The previous single-file layout mixed stack defaults, every compose service,
  and all service secrets in one module.
- The directory layout keeps each service edit scoped, keeps compose assets next
  to the module that references them, and preserves the host as the source of
  truth for service wiring.
