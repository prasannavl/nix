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
