# Systemd User Manager Bridge Consolidated Notes (2026-03)

## Scope

Consolidates the March 2026 iteration cycle around
`lib/systemd-user-manager.nix`, which exists to make generated `systemd --user`
units behave more like NixOS-managed system units during `nixos-rebuild switch`.

## Stable design

- Podman-generated user units are bridged through system units so definition
  changes participate in old-generation stop and new-generation start.
- One reload unit is generated per user manager and bridge units order
  themselves after it, so `systemctl --user daemon-reload` runs once per user
  before bridge starts.
- Bridge and reload units act only when the user manager is active, gated by
  `ConditionPathExists=/run/systemd/users/<uid>`.
- Both units are also installed under `user@<uid>.service` in addition to
  `multi-user.target`, which gives them another activation edge once the user
  manager actually exists and closes the boot race.

## Bridge lifecycle

State lives under `/run/nixos/systemd-user-manager/`:

- `<bridge>.was-active`: old generation observed the target unit as active.
- `<bridge>.stop-seen`: old generation bridge stop executed.

Start logic:

1. `was-active` present: restart the user unit and clear markers only after the
   restart command is successfully issued.
2. `stop-seen` present without `was-active`: keep the unit inactive.
3. No markers: treat as a new bridge/service and start it once.

Stop logic:

- Always attempt `systemctl --user --machine=<user>@ stop <unit>`.
- Compute active-state marker semantics separately so transient `is-active`
  query races do not suppress stop execution or lose restart intent.

## Transport/retry policy

- Control remains on `systemctl --user --machine=<user>@`; there is no `runuser`
  fallback path.
- Retry handling is kept inline in the generated scripts for transient transport
  and bus readiness errors.
- The temporary experiments with manager-level `Restart=on-failure`,
  `bindsTo=user@<uid>.service`, unconditional marker fallback, and persistent
  `.seen` state were all superseded.

## Practical meaning

- Changed active user units are stopped by the old generation and restarted by
  the new generation.
- Changed inactive units stay inactive.
- Newly introduced units start once on first activation.
- User-manager availability still defines the boundary: if the user manager is
  not running, bridge behavior is deferred rather than forcing it alive.

## Canonical interpretation

Treat this file as the canonical summary for the following superseded March 2026
notes:

- `pvl-systemd-user-manager-daemon-reload-on-switch-2026-03-02.md`
- `pvl-systemd-user-manager-per-user-reload-ordering-2026-03-03.md`
- `pvl-systemd-user-manager-bridge-marker-fallback-2026-03-03.md`
- `pvl-systemd-user-manager-start-new-bridge-unit-2026-03-03.md`
- `pvl-systemd-user-manager-user-at-uid-ordering-2026-03-03.md`
- `pvl-systemd-user-manager-only-when-active-2026-03-03.md`
- `pvl-systemd-user-manager-remove-seen-marker-2026-03-03.md`
- `pvl-systemd-user-manager-new-bridge-start-detection-2026-03-03.md`
- `pvl-systemd-user-manager-parity-and-deviations-2026-03-03.md`
- `pvl-systemd-user-manager-boot-race-user-at-wantedby-2026-03-04.md`
- `pvl-systemd-user-manager-restart-replay-hardening-2026-03-04.md`
- `pvl-systemd-user-manager-stop-path-hardening-2026-03-04.md`
- `pvl-systemd-user-manager-machine-transport-fallback-2026-03-04.md`
- `pvl-systemd-user-manager-script-dedup-2026-03-04.md`
- `pvl-systemd-user-manager-no-block-start-and-manager-retry-2026-03-04.md`
- `pvl-systemd-user-manager-startlimit-unit-section-fix-2026-03-04.md`
- `pvl-systemd-user-manager-ordering-over-retry-2026-03-04.md`
- `pvl-systemd-user-manager-ordering-with-manager-retry-reconcile-2026-03-04.md`
- `pvl-systemd-user-manager-remove-bindsto-and-was-active-restart-2026-03-04.md`
- `pvl-systemd-user-manager-marker-consumption-on-start-success-2026-03-04.md`
- `pvl-systemd-user-manager-inline-retry-no-service-restart-2026-03-04.md`
