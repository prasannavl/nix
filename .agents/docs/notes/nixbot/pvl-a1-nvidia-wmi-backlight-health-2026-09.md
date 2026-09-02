# `pvl-a1` NVIDIA WMI backlight health failure, 2026-09

## Incident

Nixbot run `aFBveq`, started September 2, 2026 at `16:34:49 +0800`, switched
`pvl-a1` to
`r3a64n79ib38fzra6h1cqf29kv7vjajw-nixos-system-pvl-a1-26.05.20260831.5dfba62`.
Build, closure copy, activation, profile promotion, and bootloader update
succeeded. The run was summarized as `FAIL (health)` because the post-switch
health check found:

```text
systemd-backlight@backlight:nvidia_wmi_ec_backlight.service loaded failed failed
```

Retained diagnostics are under `/var/tmp/nixbot/diag-aFBveq`.

## Why the pre-switch reset did not hide it

The reset worked. At `14:08:20 +0530`, the retained deploy output and target
journal show Nixbot listing this exact failed unit and running the unscoped
`systemctl reset-failed`. That operation clears the recorded failed state; it
does not fix the service, prevent later activation, or exempt the unit from the
post-switch check.

The target submitted activation at `14:08:40 +0530` and completed it at
`14:08:44 +0530`. At `14:09:11 +0530`, `systemd-logind` attempted to write a new
brightness through `nvidia_wmi_ec_backlight` and received `EIO`. The device's
udev state carries
`SYSTEMD_WANTS=systemd-backlight@backlight:nvidia_wmi_ec_backlight.service`, so
the now-reset instance was eligible to start again. Its restore write failed
five times and ended in `start-limit-hit`; the health check therefore observed a
new post-reset failure.

This is the intended reset/health semantic. Ignoring a unit merely because the
same name failed before the switch would also hide services that genuinely fail
again during activation.

## Hardware-facing cause

On the booted Linux 7.2.2 system, the kernel driver reports:

```text
nvidia-wmi-ec-backlight ...: EC backlight control failed: AE_NOT_FOUND
```

The NVIDIA WMI backlight device remains readable and reports current brightness,
but writes through its ACPI/WMI level method fail and are surfaced to userspace
as `EIO`. During validation it was the only device currently exposed under
`/sys/class/backlight`; `amdgpu` logged that it skipped DM backlight
registration, and NVIDIA modeset logged that no NVIDIA native backlight was
available. Physical or firmware-mediated brightness changes can still update the
readable value, so apparent panel brightness changes do not prove that the
userspace write path works.

The same boot recorded this failure at initial backlight restore and after
subsequent failed-state resets. It is therefore a persistent firmware/kernel
interface problem exposed by fresh brightness activity, not stale systemd state
surviving Nixbot's reset.

## Remedy boundary

Keep the general Nixbot health behavior fail-closed. Do not add a global
backlight exception or a post-switch `reset-failed`, because either would hide
new service failures.

If the unit should remain visible and usable but must not decide deploy health,
add an exact-name, host-scoped Nixbot inventory policy. The intended shape is:

```nix
pvl-a1 = {
  healthCheck.ignoredFailedSystemUnits = [
    "systemd-backlight@backlight:nvidia_wmi_ec_backlight.service"
  ];
};
```

Nixbot validates this policy as a unique list of non-empty, whitespace-free unit
names. It passes the selected host's list into the remote health command,
excludes exact first-field matches only from the system failed-unit verdict, and
logs the excluded rows as ignored host policy. It does not affect user units,
similarly named units, activation diagnostics, or any other host.

Alternatively, resolve the underlying behavior declaratively on `pvl-a1` after
validating the desired brightness path:

1. Select a working kernel/firmware backlight interface so software brightness
   writes and restore both succeed.
2. If firmware keys are the intended control path and restore through this
   instance is deliberately unnecessary, suppress only
   `systemd-backlight@backlight:nvidia_wmi_ec_backlight.service` on `pvl-a1`.
   This gives up systemd save/restore for that device and does not repair
   `systemd-logind` writes, so it needs an interactive brightness validation.

## Implementation and validation

The inventory now assigns only the NVIDIA WMI backlight instance to `pvl-a1`'s
`healthCheck.ignoredFailedSystemUnits`. Nixbot validates and resolves that
policy generically; the exception is not hard-coded into the health
implementation.

Regression coverage proves valid canonical-resource resolution, invalid-policy
rejection, exact matching, continued failure for similar system units and user
units, multi-unit remote quoting, successful-but-visible ignored failures, and
normalized console output. The packaged Nixbot helper check passed all 245
tests. The repository diff lint also passed its no-IFD root-output checks and
evaluated all seven affected NixOS hosts.

Diagnosis and implementation made no live unit-state, kernel-module, firmware,
or deployment change.
