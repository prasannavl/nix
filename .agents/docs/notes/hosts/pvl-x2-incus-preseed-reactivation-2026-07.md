# pvl-x2 Incus Preseed Reactivation 2026-07

## Incident

A `pvl-x2` deploy on 2026-07-12 failed during activation after the
pre-activation Podman image pull phase completed. The failing unit was
`incus-cert-delegation-abird-stage.service`:

```text
Ensuring project abird-stage on existing delegated Incus trusted certificate ...
Error: Project not found
```

Live inspection showed the parent Incus daemon had projects `abird`,
`abird-dev`, `default`, and `pvl`, but no `abird-stage`. The deployed
`incus-preseed.yaml` already declared `abird-stage`, its storage pool, bridge,
and profile, so the host declaration was not the bad input.

## Root Cause

`incus-preseed.service` is an upstream `RemainAfterExit=true` oneshot wanted by
`incus.service`. On the failed host it was still `active (exited)` from
2026-07-09 and had not run during the 2026-07-12 switch. Repo-owned parent Incus
helper units, including certificate delegation, are attached to
`sysinit-reactivation.target`, so they can run in the reactivation phase while
preseed is only considered already active from an earlier generation.

`Wants=incus-preseed.service` plus `After=incus-preseed.service` on dependent
units is not sufficient when live fabric objects have drifted or disappeared and
the preseed oneshot remains active.

## Fix

The Incus module now extends `incus-preseed.service` when local preseed exists:

- adds `sysinit-reactivation.target` to `wantedBy`
- adds a restart trigger for the generated preseed YAML
- keeps the existing preseed migration hook on the same unit when migrations are
  configured

This makes parent fabric convergence part of the same reactivation phase as the
dependent certificate, route, image, and instance helpers. Certificate
delegation still stays ordered after `incus-preseed.service`.

## Validation

Focused validation used:

- `nix build --no-link .#checks.x86_64-linux.lib-incus-module`
- `nix build --no-link .#checks.x86_64-linux.lib-incus-helper`
- `nix build --no-link .#nixosConfigurations.pvl-x2.config.system.build.toplevel`

The `pvl-x2` evaluation showed `incus-preseed.service.wantedBy` containing both
`incus.service` and `sysinit-reactivation.target`, with a restart trigger
pointing at the generated `incus-preseed.yaml`.
