# Activation user-unit progress in the deploy UI

Status: implemented; tests pass; no live deployment performed.

## Problem

`switch-to-configuration-ng` restarts every active target in each user manager
on every switch. On pvl-x2 each `pvl-<service>-ready.target` is
`PartOf=pvl-<service>.service`, so one activation stops and starts all ~25
rootless podman-compose stacks. Measured on system-980: 46s stopping (16:53:21 →
16:54:08), 75s starting (16:54:08 → 16:55:23), ~120s activation total.

The UI showed nothing for that window: s2c-ng filters `.target` units from its
lifecycle lines, and the compose services are only cycled through the `PartOf`
cascade, so neither appears in `stopping|starting the following user units:`.

## Change

During admitted activation, the observer samples pending systemd jobs for the
users declared by `ConditionUser=` in `/etc/systemd/user/*-managed.target`.
These jobs are manager-wide, not attributed to the switch. Waiting and running
jobs count; `start`, `stop`, `restart` and `reload` stay distinct.

Record: `[user-jobs] user=<u> action=<job-type> count=<n> units="<a,b,c>"`.

```text
[user-jobs] pvl user manager: 18 pending start jobs: pvl-dockge.service, pvl-immich.service, pvl-nginx.service (+15)
```

- Show up to three exact unit names. Omit invalid names or names that do not
  fit; keep the total. Legacy `[user-units]` and `[system-units]` are unchanged.
- Changed snapshots are rate- and line-limited per user and job type. A
  successful empty snapshot resets deduplication for that type.
- The sampler owns a Bash job process group. A timed-out account or manager
  query stops sampling for that observer, not activation. A pass stops starting
  new queries after its time budget. Observer exit or cancellation kills the
  sampler group and reaps its worker. Terminal reattachment skips sampling. The
  activation result marker and log follower are unchanged.

## Verification

- Fixed passwd and manager fixtures cover blocked query descendants, timeout
  while activation is still running, EOF on both streams, direct termination
  during startup, terminal reattachment, exact names, job types and
  deduplication.
- Scoped `nix fmt` and the `abird-host-manager` diff lint passed (1,172 tests
  passed, 3 existing ignores). No live deployment performed.
