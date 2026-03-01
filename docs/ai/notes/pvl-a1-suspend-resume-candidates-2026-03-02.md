# pvl-a1 suspend/resume failure candidates (2026-03-02)

## Context
- Host: `pvl-a1` (ASUS FA401WV class config, AMD iGPU + NVIDIA dGPU, `supergfxd` enabled).
- Symptom: system suspends, then often requires hard reboot / appears to restart instead of resuming.
- Kernel at runtime: `6.19.3`.
- Sleep type at runtime: `/sys/power/mem_sleep` shows only `[s2idle]` (no deep sleep option).

## Direct evidence from journal
- Many boots show `PM: suspend entry (s2idle)` with no `PM: suspend exit`.
- `nvidia-suspend.service` and `pre-sleep.service` complete before sleep entry, so failure happens after handoff to kernel/device resume path.
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
- `2026-02-20` flake update to nixpkgs `6d41bc...` (kernel line moved to `6.19.2` generations).
- `2026-02-22` flake update to nixpkgs `c217913...` (kernel `6.19.3` in generations).
- `2026-02-24` `a5ecd8e` "Update nvidia driver"
  - NVIDIA package moved to `580.126.18`.
  - `dynamicBoost.enable` default changed toward enabled in shared module (locally overridden to false for this host, but still relevant to code path changes in this period).
- `2026-03-02` flake update to nixpkgs `1267bb...` (still kernel `6.19.3`).

## Ranked candidate causes
1. Kernel + platform regression in `6.19.3` suspend/resume on this ASUS AMD+NVIDIA hybrid setup.
2. NVIDIA open module `580.126.18` interaction with s2idle resume path.
3. PRIME topology change (`reverseSync.enable = true`) introduced in the same update window.
4. `supergfxd` runtime power management transitions around suspend/resume.
5. NVIDIA WMI/ACPI backlight path (`nvidia_wmi_ec_backlight`) causing post-resume display bring-up failure (black-screen-like resume failure).

## Minimal, high-signal A/B tests
1. Boot previous generation with kernel `6.19.2` and test suspend/resume twice.
2. Keep current kernel; switch NVIDIA package back to pre-`580.126.18` revision and retest.
3. Disable `prime.reverseSync.enable` and retest.
4. Temporarily disable `services.supergfxd` and retest.
5. If black-screen persists, blacklist `nvidia_wmi_ec_backlight` and retest panel wake.

## Useful commands
- Check sleep mode:
  - `cat /sys/power/mem_sleep`
- Check suspend/resume markers in previous boot:
  - `journalctl -b -1 | rg "PM: suspend (entry|exit)"`
- Look for likely GPU/ACPI issues:
  - `journalctl -b -1 -k | rg -i "nvidia|amdgpu|acpi|wmi|suspend|resume"`
