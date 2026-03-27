# Incus Post-Activation Reconcile And Nixbot Settle

## Context

`lib/incus.nix` first gained activation-time guest reconcile so a parent Incus
host could recreate declared child guests that had been manually deleted or
stopped.

That initial model later gained `off|best-effort|strict` policy control so
parent-host activation did not have to fail just because one child guest was in
bad shape.

The model still proved unsafe once nested Incus hosts entered the graph. A
containerized Incus parent could complete `switch-to-configuration` while still
finishing in a partially converged runtime state if it reconciled its own child
guests during activation. The concrete failure mode was stale
`/run/current-system` after a successful switch, which made the activated host
look like it was still on the bootstrap image PATH.

The same investigation also confirmed a separate guest-side regression: optional
Tailscale configuration in `lib/incus-vm.nix` no longer enabled
`services.tailscale`, so guests with an auth secret evaluated Tailscale config
without starting the service.

## Decision

- Remove guest reconcile from `system.activationScripts`.
- Keep the final safe default as:
  - non-container Incus parents default to `best-effort`
  - containerized Incus parents default to `off`
- Add explicit host-side helper commands:
  - `incus-machines-reconcile`
  - `incus-machines-settle`
- Add a reusable `incus-machines-reconcile.service` oneshot for host-side
  reconcile outside activation.
- Keep boot-time auto-reconcile opt-in via
  `services.incusMachines.autoReconcile` instead of coupling it to activation or
  boot success.
- Teach `nixbot` to reconcile and settle Incus child guests on their parent host
  before trying snapshot/deploy waves for those guests.

## Implementation

### `lib/incus.nix`

- `services.incusMachines.reconcilePolicy` is the reconcile control.
- `services.incusMachines.autoReconcile` controls whether
  `incus-machines-reconcile.service` is wanted by `multi-user.target`.
- Activation-time reconcile is no longer used as the steady-state model.
- The host installs:
  - `incus-machines-reconcile`
  - `incus-machines-settle`
- `incus-machines-settle` waits for:
  - instance exists
  - status is `Running`
  - `incus exec <name> -- true` works
  - expected static IPv4 is reported by Incus

### `hosts/nixbot.nix`

- Child hosts now declare `parent` so deploy orchestration has an explicit
  readiness edge instead of inferring from SSH topology.
- `parent` also implies the deploy ordering/dependency edge, so parent/child
  hosts no longer need duplicate `after = [parent]` entries.

### `pkgs/nixbot/nixbot.sh`

- Before each deploy wave snapshot, `nixbot` applies generic parent readiness
  barriers for selected child hosts.
- The current default parent barrier templates call:
  - `/run/current-system/sw/bin/incus-machines-reconcile`
  - `/run/current-system/sw/bin/incus-machines-settle`
- Those command templates live in host metadata/defaults rather than being
  hard-coded into `nixbot` terminology, so the orchestration model stays generic
  even though the current implementation is Incus-backed.
- Parent readiness is batched by parent/template pair only when both templates
  support `{resourceArgs}`. Templates that only use `{resource}` run per child
  so batching never drops later resources silently.
- `nixbot` now derives parent hosts into both:
  - dependency expansion when a child is selected
  - predecessor ordering when waves are built
- `after` remains available for non-parent ordering edges that do not imply the
  parent readiness contract.

### `lib/incus-vm.nix`

- Optional Tailscale guest configuration now also sets
  `services.tailscale.enable = true`.
- Runtime hostname convergence stays in a dedicated `hostname(1)` oneshot rather
  than mixed into the guest bootstrap workaround path.

## Operational Effect

- Host activation no longer performs child guest lifecycle mutation.
- Child guest auto-heal remains available through explicit host-side reconcile.
- `incus-machines-reconcile.service` is re-runnable with a plain
  `systemctl start`, instead of staying active after the first successful run.
- `nixbot` ordering edges now gain a concrete readiness barrier for Incus
  parent/child relationships.
- Nested Incus hosts avoid mutating children during their own activation.

## Superseded notes

- `docs/ai/notes/services/incus-guest-reconcile-on-activation-2026-03.md`
- `docs/ai/notes/services/incus-reconcile-policy-best-effort-2026-03.md`
- `docs/ai/notes/plans/incus-nested-reconcile-and-deploy-readiness-2026-03.md`
