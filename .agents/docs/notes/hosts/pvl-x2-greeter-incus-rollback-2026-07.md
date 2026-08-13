# `pvl-x2` greeter failure and confirmed capacity collapse

## Incident

Nixbot run `xIrDzk`, started July 25, 2026 at `23:35:20 +0800`, reported the
required `pvl-x2` deploy and host-local rollback as failed. The deploy took
`9m59s`; both deploy and rollback returned status 4.

The output contains many progress rows, but they represent three distinct
conditions rather than one growing list of failures.

## Deploy exit status

The new generation completed secret activation, `/etc` update, Podman drains,
user service convergence, system service restart, and the two Incus automatic
start waves. The decisive error was the active `gdm-greeter` user manager:

```text
Failed to start user unit gnome-session@gnome-login.target
warning: user activation for gdm-greeter failed
```

`switch-to-configuration-ng` records any failed user activation as exit status
4, continues the remaining system switch, and exits 4 at the end. The `pvl`
manager did not fail in this deploy; its long Podman readiness jobs completed
before system restart continued.

The Incus rows were progress, not the recorded failure. The generated controller
admits two readiness waves:

1. `abird.abird-nest` and `gap3-gondor`;
2. `pvl-vlab` and `pvl-vlab-1`.

Each wave owns an `incus-machines-settlement --timeout 180` job. Live journal
and unit state showed that both settlement jobs completed successfully in about
three seconds. They did not explain the activation's long tail or exit status 4.
The reported `9m59s` deploy duration also includes copying 1,299 store paths,
Podman convergence, and the system and user switch work.

## Rollback exit status

Rollback activated the saved `6xagdnwcxkjwmmnfsky1nrw7iqry93wg` generation,
drained and restored the Podman graph, and again restarted the Incus graph. Its
active greeter identity was now the old `gdm-greeter-2` manager. That user
activation failed on:

- `gnome-session@gnome-login.target`;
- `org.freedesktop.IBus.session.GNOME.service`;
- `org.gnome.SettingsDaemon.Smartcard.target`.

Those failures set rollback status 4. `cups.service` appeared failed during the
rollback progress probes, but it was absent from the final failed-unit report
and was not the rollback exit-code owner.

## Confirmed host outage

Immediately after rollback, the LAN address answered ICMP and accepted TCP port
22 but never produced an SSH banner, while the Tailscale address did not reply.
The host later recovered sufficiently for read-only inspection. Both
`/run/current-system` and the persistent system profile pointed to the saved
`6xagdnwcxkjwmmnfsky1nrw7iqry93wg` generation, proving that rollback restored
the old generation despite nixbot reporting its switch as failed.

The journal then established a separate, real host-capacity failure:

- At `23:44:20`, the active greeter's GNOME Shell crashed in `libmutter`; the
  replacement greeter could not find a matching session. This caused the new
  generation's user-activation status 4.
- At `23:45` and `23:48`, both Incus settlement waves completed successfully in
  two to four seconds.
- From `23:58`, journald repeatedly flushed caches under memory pressure.
- At `00:00:24`, the kernel's global OOM killer killed a Java process in the
  active outer `abird/abird-corp` instance. Further global OOM kills affected
  coredump processing and Java workloads in the active, development, and nested
  Gondor Corp/data instances through at least `06:07`.
- At `06:06`, prolonged Incus database transaction timeouts and bad connections
  ended in an `incusd` nil-pointer panic. Systemd restarted Incus, and its
  lifecycle and settlement units subsequently converged successfully.

The 62 GiB host had no swap. After recovery it still used about 59 GiB, with
only about 3.3 GiB available and measurable memory and I/O pressure. Live cgroup
accounting attributed about 27.3 GiB to `gap3-gondor`, including its nested Corp
and Rivendell workloads, about 13.5 GiB to the active outer Corp instance, and
about 8.4 GiB to the development outer Corp instance. Aggregate resident demand
therefore left too little headroom for a full stop/start cycle.

`atop` was a secondary pressure amplifier rather than the initiating cause. Its
post-midnight restart scanned and copied historical raw logs, read about 16.3
GiB, wrote about 4.5 GiB, and timed out. `atop.service`, `atop-rotate.service`,
and several coredump units remained failed after recovery because their work ran
inside the already exhausted host.

## August 10 recurrence

Nixbot run `zeJbAm`, started August 10, 2026 at `17:51:42 +0800`, selected only
`pvl-x2`. It copied 3,153 store paths and submitted the new generation's
activation. Most of the reported `27m37s` deploy duration was closure transfer;
the activation reached its final Incus work in about two minutes.

At `18:18:48`, reloading the active UID 60578 `gdm-greeter` manager shut down
GNOME Shell. The shell dumped core with `SIGSEGV`. The reexecuted manager then
tried to start `gnome-session@gnome-login.target`, but GNOME Shell reported
`Failed to find any matching session`. The dependent SettingsDaemon, IBus, and
portal failures made `switch-to-configuration-ng` return status 4. Both Incus
automatic-start waves completed successfully in three to four seconds.

Rollback activated the saved
`wrmnr5b0za3zp9hsdpn3v927f1fjk92k-nixos-system-pvl-x2-26.05.20260724.597283a`
generation. It returned status 4 after the same no-matching-session failure in
the UID 60579 `gdm-greeter-2` manager. Two additional rollback transitions did
not persist:

- `incus-gap3-gondor.service` timed out after 90 seconds while stopping, then
  restarted successfully with the restored graph;
- `systemd-hostnamed.socket` briefly refused to start while
  `systemd-hostnamed.service` was already active, then cleared when the service
  exited.

Live readback proved both current-system and the persistent system profile
pointed to the saved generation. The system reported `running` with no failed
units, every declared Incus lifecycle unit was active, all three parent
instances were running, and both Incus settlement services had succeeded. The
host had about 35 GiB available memory with no memory pressure or OOM event, so
the July capacity collapse did not recur.

This recurrence confirms the GDM failure is deterministic enough to block an
otherwise healthy deploy. The narrow correction belongs in user-switch planning:
transient, display-manager-owned greeter managers must not synthesize
graphical-session targets after their logind session has been torn down. Do not
ignore status 4 globally; activation failures for ordinary users must remain
visible and fatal.

## Resolution design

The failed generation's exact `switch-to-configuration-ng` source has two
generic rules that combine badly for a display-manager greeter:

1. the system-scope parent iterates every result from `logind.list_users()` and
   runs the user-switch child without classifying the user;
2. the child records every active target for a later start unless the target has
   `RefuseManualStart=yes` or the NixOS-specific `X-OnlyManualStart=yes`
   directive.

The preferred correction is to exclude display-manager-owned transient greeter
identities from the generic per-user switch. The exclusion should be generated
from display-manager configuration rather than inferred from a username pattern.
GDM remains responsible for replacing its greeter and establishing the matching
logind session. Regular and lingered user managers must still run the normal
switch, and their status 4 failures must remain fatal.

If that boundary cannot be added immediately, a narrower package/module
mitigation is to mark every unit in the greeter's session-owned graph with
`X-OnlyManualStart=yes`. Marking only `gnome-session@gnome-login.target` is
insufficient because the switch independently snapshots and restarts active
SettingsDaemon, X11-session, IBus, and portal units.

The operational workaround is a maintenance-window switch with the display
manager stopped and its greeter manager fully exited, followed by an explicit
display-manager start. It is disruptive and should not become the normal deploy
path.

### Boot-goal workaround

A `boot` goal avoids the live user-switch path entirely. The target
`switch-to-configuration` installs the boot entry, syncs the store, and exits
before system or user units are migrated. Nixbot persists the target system
profile and bootloader entry but does not reboot the host.

Current nixbot behavior needs two guardrails for this workaround:

- post-deploy health checks inspect the still-running old generation and are not
  evidence that the target generation booted successfully;
- rollback is hard-coded to use the `switch` goal, even when the failed deploy
  requested `boot`, so automatic rollback can re-enter the GDM failure.

Use the boot goal with immediate verification and automatic rollback disabled,
then perform a controlled reboot with the saved generation available for boot
menu recovery. After reboot, verify current-system and the persistent profile
both point to the target, system state is healthy, and the Incus and Podman
graphs have converged.

A durable nixbot improvement should make rollback goal-aware (`boot` restores
the previous boot default without live activation) and represent boot-goal
verification as pending until a post-reboot observer confirms the target
generation.

### Boot-goal validation on 2026-08-11

After staging the generation with the `boot` goal and rebooting, direct LAN SSH
validation confirmed that `/run/current-system` and the persistent system
profile both resolved to
`pwrcbjlnz5scbwi4xg5dqj1lhr866ckb-nixos-system-pvl-x2-26.05.20260808.8b8c811`.
The host booted kernel `7.1.7`; systemd reported `running`, had no pending jobs,
and had no failed system or `pvl` user units.

GDM was active with a fresh `gdm-greeter` Wayland session. The journal contained
none of the live-switch failure signatures: no greeter segmentation fault, no
missing matching session, no failed `gnome-login` target, and no status 4 user
switch result.

Both Incus automatic-start settlement jobs completed successfully with status 0
at `14:49:15` and `14:49:20 +08`. The preseed, reconciler, limits, and routes
jobs also reported success, `incus.service` was running, and all six listed
instances were running. All 18 rootless Podman containers were running and all
12 declared application-ready targets were active. Immich Redis's first health
check failed while the container was starting, then became healthy about 30
seconds later and remained healthy; this was startup convergence rather than a
persistent unit failure.

No boot-scoped kernel error, OOM, Incus panic, or watchdog failure was present.
Available memory stabilized around 29 GiB and load fell from 17.22 to 7.10 over
the observation window. The host still has no swap, so the previously recorded
capacity risk remains even though this boot had healthy headroom.

Two non-blocking application warnings remain outside the boot-goal result.
`docmost_redis_1` reported that memory overcommit is disabled, confirmed by
`vm.overcommit_memory=0`, and Portainer reported that no administrator account
is configured. Both applications reached their declared ready targets, but the
warnings need separate configuration and security review.

## Classification

- Fix the GDM and session-scoped user-switch ownership boundary to remove the
  false deploy/rollback status 4 and unnecessary rollback.
- Treat aggregate resident memory and restart headroom as a separate physical
  capacity problem. Incus start waves worked as designed; lower concurrency or
  longer activation timeouts cannot fix steady-state demand near host capacity.
- Do not redeploy while the host has only a few GiB available and no swap. First
  reduce resident workload or add durable capacity and swap headroom, then
  verify memory and I/O pressure before another full graph restart.
- Harden `atop` rotation separately so historical-log maintenance cannot add a
  large I/O burst during an already pressured activation.
