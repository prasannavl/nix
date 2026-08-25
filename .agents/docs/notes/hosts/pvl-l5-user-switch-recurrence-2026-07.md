# `pvl-l5` recurring user-switch failure

## Incident

Nixbot run `xIrDzk` on July 25, 2026 again failed the optional `pvl-l5`
activation with exit status 4. The same signature appeared at least five times
that day:

- `00:49:03`
- `00:49:38`
- `01:04:44`
- `01:45:15`
- `23:35:51`

Each occurrence started a GNOME Shell in the long-lived `pvl` user manager
without a matching graphical logind session. GNOME Shell exited with
`Failed to find any matching session`; GNOME session failure handling then
started `gnome-session-restart-dbus.service`, stopped `dbus-broker.service`, and
disconnected the same D-Bus client that `switch-to-configuration-ng` was using
to control and observe the user-unit jobs.

## Failure classes

The activation output interleaved two related but distinct user-manager
failures:

1. The old `gdm-greeter-2` manager at UID 60579 was reexecuted while its GNOME
   login shell was active. That shell dumped core with `SIGSEGV`. GDM created a
   replacement greeter under UID 60578, while the old manager tried to start
   login-session targets without a matching logind session. The reported
   SettingsDaemon and `gnome-session-x11-services-ready.target` failures were
   dependency fallout. The obsolete UID 60579 manager then exited normally.
2. The `pvl` manager remained active through linger and SSH sessions but had no
   graphical logind session. User switching nevertheless restarted
   `gnome-session@gnome.target`; its GNOME Shell failed to find a session and
   initiated GNOME-session teardown, including the user D-Bus restart. The
   activation process consequently reported
   `Failed to process dbus messages while waiting for jobs`.

The duplicate D-Bus service-file warnings and transient GDM target failures were
not independent root causes.

## August 24 recurrence and 26.05 trigger

The optional `pvl-l5` deploy started on August 24, 2026 at 22:29:12 IST
reproduced the GDM variant in both the forward switch and rollback. During the
forward switch, `switch-to-configuration-ng` stopped changed units in the
long-lived `gdm-greeter` manager at UID 60578. GNOME Shell shut down and dumped
core with `SIGSEGV`; GDM replaced that greeter with `gdm-greeter-2` at UID
60579. The old greeter's user D-Bus then disappeared while the switch child
still had queued jobs, so the child emitted repeated `Connection is closed`
messages and finally `Failed to remove jobs token`.

Rollback repeated the transition in the other direction. It reconciled the
active `gdm-greeter-2` manager while GDM replaced it with `gdm-greeter`; the
obsolete manager attempted to synthesize `gnome-session@gnome-login.target`
without a matching logind session and then exited. The rollback's later SSH
timeout was a separate system-unit transport failure: the remote switch had
stopped changed networking and SSH-related units while crossing generations.

This behavior became visible after the 26.05 upgrade because upstream commit
[`2ff37e4`](https://github.com/NixOS/nixpkgs/commit/2ff37e4) changed
`switch-to-configuration-ng` to compare and actively stop, reload, restart, and
start changed NixOS-managed user units. Before that change, the per-user child
only reexecuted the user manager and restarted `nixos-activation.service`.
Current upstream code still iterates every user returned by logind `ListUsers`
without excluding greeter-class sessions.

After the incident, `/run/current-system` pointed to the saved pre-deploy
generation, `systemctl is-system-running` reported `running`, no system units
were failed, and only `pvl` plus the replacement `gdm-greeter` remained active
in logind. The greeter accounts were already aligned to UIDs 60578 through
60582, so stale account numbering was not the cause of this recurrence.

The durable correction is implemented at the user-selection boundary by the
`lib/ext/switch-to-configuration/` package override and registered through the
default overlay. Before spawning the per-user child, the switcher reads the
logind user's `Sessions` property and each session's `Class`. It skips
reconciliation only when at least one session is class `greeter` and every other
session is the synthetic `manager` or `manager-early` class. Manager-only
lingered users, ordinary users, and mixed greeter-plus-user sessions remain
eligible. Classification errors fail open with a warning so a D-Bus race cannot
silently suppress a real user's activation.

The package build, upstream clippy gate, and all seven Rust unit tests pass. The
new regression cases cover the observed `manager-early` plus `greeter` shape,
manager-only users, empty session sets, ordinary users, and mixed sessions. The
patched candidate was exercised by the later dirty-staged retry, but rollback
restored the saved generation, so the correction is not active in the runtime
system. Operationally, the remaining fallback is to stop
`display-manager.service` around a live switch or use the `boot` action and
reboot. Ignoring the child exit status alone would hide real user activation
failures and still tear down the greeter.

## August 24 23:46 retry and activation ownership

The next deploy used the patched package and proved the greeter correction: the
forward activation logged `skipping user units for gdm-greeter` and did not
produce the earlier D-Bus connection errors. It still failed because the system
switch stopped NetworkManager and iwd while Nixbot was observing an attached
`systemd-run --wait --pipe` over SSH. The connection timed out, the attached
client was terminated, and systemd canceled the transient activation before its
runner could replace the in-progress result marker. Recovery observed the exact
interrupted shape: `Result=running`, `ExecMainStatus=255`,
`LoadState=not-found`, and `/run/current-system` already at the candidate path.

The candidate system profile had also been promoted, but the interrupted unit
could not be accepted as a completed activation. Nixbot therefore rolled back
using the saved, unpatched generation; that old switcher reconciled the greeter
again, which is why GDM unit failures appeared only in the rollback log. After
the run, the runtime system was the saved generation, the profile was the
candidate generation, and systemd reported `running` with no failed system
units.

A controlled target test reproduced the ownership error: killing SSH after an
attached `systemd-run --wait --pipe` admission also killed the transient unit.
Submitting the same unit with `systemd-run --no-block` let it finish after the
post-admission SSH observer was killed. Nixbot now uses that detached submission
boundary and follows the retained activation log with a separate observer, so
network or sshd restarts can interrupt observation without interrupting the
target-local transaction.

## Ownership boundary

`switch-to-configuration-ng` calls logind `ListUsers` and runs a user switch for
every returned manager. Its user switch snapshots every non-inactive
NixOS-managed unit, records every active target for restart, and then starts
those targets after the manager reexecution. It does not prove that
session-scoped graphical targets still have a matching graphical logind session.

This creates a feedback loop on `pvl-l5`: an active lingered user manager can
retain or reacquire graphical targets after an earlier failed switch, and every
later deploy tries to start them again despite the user having only SSH
sessions. Retrying nixbot cannot resolve that state.

A durable correction belongs at the user-switch planning boundary: session-
scoped graphical targets must not be synthesized for managers without a matching
graphical session, and transient/obsolete GDM greeter managers must not make the
host switch fail while GDM is replacing them. Hiding the final D-Bus error or
marking more individual GNOME units non-restarting would only mask the
downstream symptoms.

During `xIrDzk`, `/run/current-system` pointed at the attempted target while the
persistent system profile still pointed at the pre-deploy snapshot, so nixbot
retained the rollback boundary.

After required host `pvl-x2` failed, nixbot ran the saved `pvl-l5` snapshot
through the same switch path. The rollback reached the old configuration and
restored both `/run/current-system` and the persistent profile to
`3716lhlrgn6kb7chw0gn7qs5n7swnf9y`, but the synthetic `pvl` GNOME start again
stopped the user D-Bus connection. The rollback therefore returned status 4 and
was summarized as failed even though the old generation was restored and no
failed system or `pvl` user units remained afterward.
