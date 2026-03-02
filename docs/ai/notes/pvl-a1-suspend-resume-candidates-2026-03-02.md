# pvl-a1 suspend/resume failure candidates (2026-03-02)

## Context

- Host: `pvl-a1` (ASUS FA401WV class config, AMD iGPU + NVIDIA dGPU, `supergfxd`
  enabled).
- Symptom: system suspends, then often requires hard reboot / appears to restart
  instead of resuming.
- Kernel at runtime: `6.19.3`.
- Sleep type at runtime: `/sys/power/mem_sleep` shows only `[s2idle]` (no deep
  sleep option).

## Direct evidence from journal

- Many boots show `PM: suspend entry (s2idle)` with no `PM: suspend exit`.
- `nvidia-suspend.service` and `pre-sleep.service` complete before sleep entry,
  so failure happens after handoff to kernel/device resume path.
- On many subsequent boots, kernel reports:
  - `x86/amd: Previous system reset reason ... hardware watchdog timer expired`
  - This strongly indicates reboot during suspend window, not a normal resume
    failure path.
- `wdctl /dev/watchdog0` shows hardware watchdog timeout of `300 seconds`.
- `/etc/systemd/system.conf` has:
  - `RuntimeWatchdogSec=5min`
  - `RuntimeWatchdogPreSec=60s`
  - `RebootWatchdogSec=5min`
- Suspend-to-next-boot gaps around ~5 minutes align with watchdog timeout
  behavior.
- Frequent NVIDIA/ACPI backlight errors:
  - `nvidia_wmi_ec_backlight ... EC backlight control failed: AE_NOT_FOUND`
  - `ACPI BIOS Error ... _SB.PCI0.SBRG.BPWM ... AE_NOT_FOUND`
- Current stack includes:
  - NVIDIA open kernel module `580.126.18`
  - `supergfxd` active in Hybrid mode, runtime PM set to Auto
  - Both `amdgpu` and `nvidia*` modules loaded

## Recent change window (last ~10-20 updates)

- `2026-02-18` `15e3e8d` "Update nvidia drivers"
  - Changed NVIDIA module wiring and defaults.
  - Enabled `prime.reverseSync.enable = true` in `lib/devices/asus-fa401wv.nix`.
  - Set driver package pathing to kernel-coupled package.
- `2026-02-20` flake update to nixpkgs `6d41bc...` (kernel line moved to
  `6.19.2` generations).
- `2026-02-22` flake update to nixpkgs `c217913...` (kernel `6.19.3` in
  generations).
- `2026-02-24` `a5ecd8e` "Update nvidia driver"
  - NVIDIA package moved to `580.126.18`.
  - `dynamicBoost.enable` default changed toward enabled in shared module
    (locally overridden to false for this host, but still relevant to code path
    changes in this period).
- `2026-03-02` flake update to nixpkgs `1267bb...` (still kernel `6.19.3`).

## Ranked candidate causes

1. Hardware watchdog (`sp5100_tco`) expiration during suspend because systemd
   runtime watchdog is enabled at 5 minutes.
2. Kernel/platform suspend stability (secondary factor) on this ASUS AMD+NVIDIA
   hybrid setup.
3. NVIDIA open module `580.126.18` interaction with s2idle path.
4. PRIME topology (`reverseSync.enable = true`) interaction.
5. `supergfxd` runtime PM transitions.
6. NVIDIA WMI/ACPI backlight path (`nvidia_wmi_ec_backlight`) causing display
   bring-up issues (likely separate from watchdog reboot).

## AMD GPU-related log interpretation

- Repeated high-severity AMD lines are primarily from `amdxdna` (NPU) probe
  failure:
  - `aie2_check_protocol: Incompatible firmware protocol ...`
  - `amdxdna_probe: Hardware init failed`
- These are NPU/firmware mismatch errors, not classic `amdgpu` display-engine
  suspend crashes.
- They should be cleaned up, but they do not line up as the direct reboot
  trigger compared to explicit watchdog reset reasons.

## Minimal, high-signal A/B tests

1. Disable runtime watchdog (`RuntimeWatchdogSec=off`) and retest suspend.
2. Keep watchdog off; test on both `6.18.13` and `6.19.3` to separate watchdog
   from kernel effects.
3. If issue persists after watchdog-off, then A/B NVIDIA version / reverseSync /
   supergfxd.
4. If black-screen persists without reboot, blacklist `nvidia_wmi_ec_backlight`
   and retest panel wake.

## Useful commands

- Check sleep mode:
  - `cat /sys/power/mem_sleep`
- Check suspend/resume markers in previous boot:
  - `journalctl -b -1 | rg "PM: suspend (entry|exit)"`
- Look for likely GPU/ACPI issues:
  - `journalctl -b -1 -k | rg -i "nvidia|amdgpu|acpi|wmi|suspend|resume"`
