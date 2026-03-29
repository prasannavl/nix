# systemd-user-manager Per-User Apply and Podman Actions (2026-03)

## Scope

Refactor `lib/systemd-user-manager.nix` away from one system bridge service per
user unit and per Podman lifecycle tag.

## Decision

- `lib/systemd-user-manager.nix` now generates one serialized reconciler service
  per user manager instead of separate system bridge services for each managed
  user unit.
- The reconciler service:
  - waits for the user manager bus to become reachable
  - runs one `systemctl --user daemon-reload`
  - cleans up removed managed entries from the previous manifest before applying
    the new generation
  - compares per-item stamp files under `/run/nixos/systemd-user-manager/`
  - reconciles changed managed units first, waits for stable user-unit state,
    and only then runs ordered transient actions
  - treats an unchanged but inactive managed unit as drift and starts it again,
    unless the unit file itself is disabled or masked
  - uses the bridge action target consistently for drift healing and
    post-action-triggered starts, so bridges with custom `changeUnit` do not
    reconcile one unit and restart another
  - emits explicit progress logs for user-manager readiness, bridge
    reconciliation, state waits, main unit actions, post-actions, and final
    success/failure summaries so deploy-time stalls are observable in the
    reconciler unit journal
  - includes elapsed timing for each bridge, each transient post-action, and the
    overall apply pass
  - continues across bridge-local failures, records the broken bridges, and
    fails once at the end instead of aborting the whole user pass on the first
    broken service
- Managed user units remain declarative through
  `services.systemdUserManager.instances`, but their semantics are now
  reconciliation-based instead of old-stop/new-start replay via per-unit bridge
  stop state.
- Activation starts each per-user reconciler unit explicitly and follows its
  journal live, so successful `switch-to-configuration` runs show
  `[systemd-user-manager] ...` progress inline without moving the reconciliation
  logic itself into activation. No-op bridges stay quiet; inline output is
  reserved for waits, actual unit changes, post-actions, stale-state cleanup,
  and failure/success summaries when work occurred.
- Follow-up lifecycle work is now modeled as `postActions` nested under each
  bridge instead of a separate global `services.systemdUserManager.actions`
  namespace.
- Per-bridge reconciliation state is kept in the apply unit's persistent
  `StateDirectory`, one state file per managed bridge, rather than split into
  separate global action and manifest stamp files under `/run`.
- The old user-identity restart stamps remain under
  `/run/nixos/systemd-user-manager/`, but bridge reconciliation state itself is
  owned by the reconciler `StateDirectory`.

## Podman integration

- `lib/podman.nix` now registers the main compose unit as a bridged user unit
  and attaches lifecycle tags as bridge-local `postActions`.
- `imageTag` and `recreateTag` are registered as transient actions instead of
  emitting persistent user oneshot units such as `pvl-foo-recreate-tag.service`.
- `imageTag` is now a pre-reconcile action only: it runs `podman compose pull`
  before any restart and does not change service state by itself.
- `recreateTag` is now a pre-reconcile action that marks the next managed
  start/restart to use `podman compose up --force-recreate`.
- `bootTag` no longer runs as a separate transient action. It remains folded
  into the main managed-unit restart trigger so the normal service stop/start
  path performs the restart when its tag changes.
- This removes the broken pattern where a separate `recreate-tag` action could
  tear down a running stack after the main service restart had already
  succeeded.

## Why

- The first failures on `pvl-x2` originated in user-manager bridge transport
  instability (`Transport endpoint is not connected`) during switch, before the
  later Podman mutation failures.
- A single per-user reconciler service gives one serialization point for bus
  readiness, `daemon-reload`, and post-reload reconciliation.
- Converting tag actions from persistent user units into transient bridge-local
  post-actions removes stale failed user units and avoids bridging side effects
  through separate old-stop/new-start state.
- Keeping post-action stamps with the bridge entry in persistent unit-owned
  state avoids the earlier bug where a global runtime stamp could consume a
  declarative tag change without ever running the requested action, and it keeps
  pending tag transitions durable across reboot.

## Constraints

- The new model intentionally favors deterministic reconciliation during the new
  generation over per-unit stop-state replay from the old generation.
- Removal cleanup is fail-closed when a removed managed user unit cannot be
  stopped while its user manager is active.
- Podman lifecycle actions still execute under the user manager, but they are
  now launched transiently by the per-user reconciler service from each bridge's
  ordered `postActions` instead of existing as durable user units.
- Transient actions must carry the same runtime `PATH` contract as the managed
  Podman user services, otherwise `podman compose` cannot locate the external
  compose provider during tag actions.
