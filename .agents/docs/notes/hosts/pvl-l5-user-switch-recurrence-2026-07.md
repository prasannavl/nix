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
