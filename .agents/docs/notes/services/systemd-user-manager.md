# Systemd User Manager

## Scope

Canonical design for the generation-driven `systemd-user-manager` bridge and its
deploy-time reconciliation of direct managed user units.

## Core model

- Desired state comes from immutable generation metadata in the Nix store.
- `/run/systemd-user-manager/applied-metadata/<user>.json` records only the last
  successfully reconciled runtime state; it is not a mutable desired-state
  database.
- Activation owns old-world stop and dry-activate preview. A normal dispatcher
  owns user-manager reload, new-world start/reload, verification, and the final
  applied-metadata commit.
- Provider lifecycle semantics stay in provider-owned units and `verifyCommand`;
  the bridge does not embed a generic action graph.

## Switching rules

- Restart and reload stamps are distinct. Restart drift participates in the
  old-world stop/new-world start handoff; reload-only drift is applied after the
  new user-manager definition is loaded.
- `transitionNeutralStamp`, `stopOnTransitionFrom`, and `stopOnTransitionTo`
  allow a provider to distinguish policy-only metadata churn from a transition
  that requires one stop/start. The bridge does not interpret provider policy
  names.
- Desired state is `running` or `stopped`. `autoStart = false` suppresses cold
  start without removing the unit from old/new generation comparison.
- Active desired-running units with `verifyCommand` are verified before applied
  metadata is committed. Failed provider verification may restart that unit once
  inside the same deterministic reconcile transaction.
- `startMode = "wait"` waits for stable active state. `startMode = "enqueue"`
  accepts a queued start and requires a transition-aware, non-blocking verifier;
  use it only for a short dispatcher whose long work has a separate explicit
  owner.
- `startConcurrency`, default four per managed user, bounds new-world start and
  restart work. `-1` means unlimited concurrency.
- Each managed unit carries its own `timeoutReadySeconds`. Dispatcher timeouts
  are only outer envelopes around those per-unit budgets and bounded stop
  cleanup.
- Before start/restart, stale failed state and residual unit-cgroup processes
  are cleared. Old-world stops are queued together and then waited as a group; a
  stuck unit gets a bounded cgroup kill and one final stopped-state check.
- Managed entries are unique by `(user, unit)`. Removed users are handled before
  account removal.

## Dispatcher behavior

- Reconciler user units are dispatcher-owned implementation details with no
  install membership and no NixOS user-activation restart/stop handling.
- Applied metadata is written only after start/reload reconciliation and
  provider verification succeed.
- Active `activating` units are joined unless an explicit restart marker says
  they must be restarted. `deactivating` and `reloading` remain recoverable
  transitional states.
- Identity changes that require `user@<uid>.service` restart are recorded during
  comparison and executed later by the dispatcher through runtime markers.
- Metadata parsing failures are fatal. Empty fields must survive serialization
  and shell parsing.
- Dispatcher progress is visible, but live unit-state polling is authoritative.
  Journal reads are bounded and rate-limited.
- Dry-activate is non-mutating and skips future managed users whose live account
  does not yet exist.

## Podman boundary

Podman Compose owns its own public managed root, per-instance stage/main/verify/
ready graph, provider transaction, runtime preflight, and optional reconcile
leaf. It no longer registers Compose instances with
`services.systemd-user-manager.instances`. `systemd-user-manager` remains the
generic bridge for direct non-Podman user services.

Podman main units use `KillMode=mixed`: the provider helper owns graceful
container cleanup, while systemd is the hard-kill backstop for stuck helper
children. Provider `postStart` hooks run after the rootless mutation transaction
is released.

## Source of truth

- `lib/systemd-user-manager/default.nix`
- `lib/systemd-user-manager/helper.sh`
- `docs/systemd-user-manager.md`
