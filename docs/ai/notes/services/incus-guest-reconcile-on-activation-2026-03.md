# Incus Guest Reconcile On Activation

## Context

`pvl-x2` declares Incus guests like `llmug-rivendell` and `gap3-gondor` through
`lib/incus.nix`, and `nixbot` deploys those guests in later dependency waves.

When a guest was manually deleted in Incus, a later parent-host deploy did not
recreate it automatically. The per-guest `incus-<guest>` lifecycle units are
oneshot services with `RemainAfterExit = true`, so `nixos-rebuild switch` did
not rerun them just because the runtime object disappeared. That left the guest
unreachable, caused snapshot capture to fail, and triggered rollback of earlier
successful hosts.

## Decision

Reconcile declared Incus guests during parent-host activation. If a declared
guest is missing or not running, restart its `incus-<guest>` lifecycle service
from an activation script.

Keep `recreateTag` as the explicit knob for forced recreate when the guest still
exists and is already running.

## Implementation

- `lib/incus.nix` adds `system.activationScripts.incusMachinesReconcile`.
- The activation script:
  - exits quietly if the Incus daemon is not available yet
  - inspects each declared guest with `incus list <name> --format json`
  - restarts `incus-<guest>.service` when status is `missing` or anything other
    than `Running`

## Operational Effect

- Manually deleted Incus guests are recreated on the next parent-host deploy.
- Manually stopped declared guests are started again on the next parent-host
  deploy.
- Later `nixbot` guest snapshot/deploy waves no longer depend on an operator
  remembering to bump `recreateTag` or restart the guest lifecycle unit after
  deleting a guest by hand.
