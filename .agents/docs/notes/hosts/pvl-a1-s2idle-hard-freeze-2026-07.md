# `pvl-a1` s2idle hard freezes

## Scope

This note records the July 29, 2026 read-only investigation of intermittent
suspend failures on `pvl-a1`, an ASUS TUF Gaming A14 FA401WV. No live changes
were made during the investigation.

The evidence covers the ten most recent journal boots, `-9` through `0`, on July
20-29, 2026.

## Observed pattern

The failures are real and repeatable, but suspend does not fail on every
attempt:

| Boot | Suspend entries | Suspend exits | Final disposition                  |
| ---- | --------------: | ------------: | ---------------------------------- |
| `-9` |               0 |             0 | Clean shutdown                     |
| `-8` |               0 |             0 | Clean shutdown                     |
| `-7` |               0 |             0 | Clean shutdown                     |
| `-6` |               1 |             0 | Crash after suspend entry          |
| `-5` |               3 |             2 | Crash after final suspend entry    |
| `-4` |               4 |             3 | Crash after final suspend entry    |
| `-3` |               1 |             0 | Crash after suspend entry          |
| `-2` |               1 |             0 | Crash after suspend entry          |
| `-1` |              14 |            13 | Crash after final suspend entry    |
| `0`  |               0 |             0 | Current boot at investigation time |

Across the affected boots, 18 suspend/resume cycles completed and six final
suspend attempts did not. Each failed boot ends at:

```text
systemd-sleep: Performing sleep operation 'suspend'...
kernel: PM: suspend entry (s2idle)
```

There is no matching `PM: suspend exit`, systemd resume completion, orderly
shutdown, OOM, or watchdog reset. `last -x` classifies all six boots as crashes.
The pre-sleep Incus hook completes, and systemd successfully freezes
`user.slice`, so the Incus helper and ordinary userspace shutdown are not the
blocking seam.

Boot `-1` is especially diagnostic. The laptop woke while its lid remained
closed, then logind re-suspended it about 25 seconds later. This repeated 13
times before the fourteenth suspend became unrecoverable. The successful sleep
durations ranged from about one minute to more than two hours.

## Effective platform state

- Firmware exposes only `[s2idle]`; S3/deep sleep is unavailable.
- The failures reproduce on Linux `7.1.3` and `7.1.4`.
- Every affected boot uses the NVIDIA `595.84` open kernel module in Hybrid mode
  with an AD107M RTX 4060 and an AMD Strix iGPU.
- NVIDIA power management is enabled with fine-grained runtime D3,
  `NVreg_PreserveVideoMemoryAllocations=1`, and
  `NVreg_UseKernelSuspendNotifiers=1`.
- The GPU and platform report S0ix support, but
  `NVreg_EnableS0ixPowerManagement=0` leaves the NVIDIA S0ix path disabled.
- A successful resume in boot `-4` emitted repeated
  `RmHandleDNotifierEvent ... status=0x11` failures from the NVIDIA driver.
- Power-source and USB-C events repeatedly try to start or stop
  `nvidia-powerd.service`, but the unit is absent because this host disables
  Dynamic Boost.
- The MediaTek MT7922 reconnects normally after successful resumes and does not
  show the `pci_pm_resume` timeouts seen on `pvl-l5`.
- `amd_pmc: Last suspend didn't reach deepest state` appears on two short,
  successful cycles. It identifies imperfect S0ix entry, but does not precede
  the six terminal hangs.
- BIOS `322` is the current release on the
  [ASUS FA401WV support page](https://www.asus.com/ca-en/supportonly/fa401wv/helpdesk_bios/).
  The repo still disables AMD CPU microcode loading with an old "until BIOS
  update" comment; the running revision is `0x0b20401b`.
- Hibernation is not currently resume-ready: `/sys/power/resume` is `0:0` and
  `/sys/power/resume_offset` is `0`.

## Cause assessment

There are two interacting problems.

First, the platform has a spurious-wakeup problem. In s2idle, ordinary in-band
device interrupts can wake the system, as described by the
[kernel sleep-state documentation](https://docs.kernel.org/admin-guide/pm/sleep-states.html).
`pvl-a1` currently enables wake for four xHCI controllers, a USB4/Thunderbolt
controller, USB-C power supplies, RTC, lid, keyboard, and power button. The
closed-lid wake/re-suspend storm is consistent with an unfiltered USB, USB-C,
RTC, or ACPI wake source. The journal does not identify the exact IRQ because
`pm_debug_messages` and `pm_print_times` are disabled.

Second, the terminal hard freeze is most likely in the NVIDIA hybrid power path.
The combination of Linux 7.1, NVIDIA 595.84, hybrid graphics, niri, and repeated
s2idle cycles closely matches
[NVIDIA open-kernel-module issue 1117](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1117),
including a NixOS 7.1.3 and 595.84 report. The host also has NVIDIA ACPI
D-Notifier failures and leaves the supported NVIDIA S0ix mode disabled. This is
a strong diagnosis, but not yet a proven stack trace: the kernel journal is
frozen after `PM: suspend entry`, and remote access did not have root permission
to read pstore or run the AMD s2idle capture tool.

The AMD display driver, MediaTek Wi-Fi, Incus pre-sleep helper, and systemd
runtime watchdog do not have comparable evidence tying them to the terminal
hangs.

## Configuration decision

Keep Hybrid graphics, Linux 7.1, and the latest NVIDIA production driver. At the
time of this investigation, the repo's NVIDIA updater reports `595.84` as
latest, so that is already the selected combination. Do not use Integrated mode
as an isolation test.

Enable `NVreg_EnableS0ixPowerManagement=1` only on the FA401WV. The existing
NixOS NVIDIA module does not explicitly disable this option; it leaves the
NVIDIA driver's conservative default of `0` unchanged. The platform and GPU both
report S0ix support, and the firmware provides no S3/deep alternative.

The change has two relevant tradeoffs. It selects a less broadly exercised
NVIDIA suspend path and therefore requires repeated validation. Also, with the
default 256 MiB threshold, NVIDIA keeps VRAM in self-refresh when usage exceeds
the threshold, which can consume more sleep power than powering VRAM off. Do not
tune the threshold in the first test so S0ix remains the only changed variable.

## Solution and validation order

1. Stop using suspend as the default lid action until one configuration passes
   repeated testing. Shutdown is the currently reliable fallback. Do not
   substitute hibernation until resume-device and Btrfs swap-file offset
   handling are configured and tested.
2. Enable `NVreg_EnableS0ixPowerManagement=1` while retaining Hybrid mode, Linux
   7.1, NVIDIA 595.84, reverse sync, and the default 256 MiB threshold. Test at
   least 20 short cycles plus one multi-hour closed-lid cycle.
3. If S0ix alone does not resolve the hard freeze, test without
   `hardware.nvidia.prime.reverseSync.enable` and without an external display on
   the NVIDIA-connected DP path.
4. Independently reduce spurious wakes. Preserve the lid and power-button wake
   paths, then disable RTC, USB host-controller, USB4, and Thunderbolt wake
   selectively through idempotent sysfs/udev ownership. Add devices back only
   when required.
5. Run the upstream
   [`amd-s2idle` tool](https://kernel.googlesource.com/pub/scm/linux/kernel/git/superm1/amd-debug-tools/)
   as root and enable `/sys/power/pm_debug_messages` plus
   `/sys/power/pm_print_times` for a test boot. After each unwanted wake,
   capture `/sys/power/pm_wakeup_irq`, match it to `/proc/interrupts`, and
   retain the generated report.
6. If the hard freeze still occurs, enable crash-surviving suspend diagnostics.
   Inspect pstore as root, consider a controlled `pm_trace` test, and preserve
   the next failure fingerprint. `pm_trace` modifies RTC state and should be
   used only for a deliberate diagnostic cycle.
7. Revisit the stale microcode exception in its own rollback-safe generation.
   BIOS 322 is already installed and current, so the original "until BIOS
   update" condition may no longer apply. Do not combine this experiment with
   the NVIDIA or wake-source changes.

The validation gate is not one successful wake. A candidate configuration must
survive repeated cycles, a long closed-lid interval, AC and battery transitions,
and the intended USB-C/display topology without a `last -x` crash or an
unmatched `PM: suspend entry`.
