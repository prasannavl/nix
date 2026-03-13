# pvl-a1 Desktop Investigations Consolidated Notes (2026-03)

## Scope

Canonical summary of the March 2026 `pvl-a1` desktop investigations covering
suspend/resume failures, GNOME idle lock behavior, and `amdxdna` firmware
mismatch noise.

## Suspend and resume

- Host is an ASUS FA401WV-class laptop using AMD iGPU + NVIDIA dGPU with
  `supergfxd` and only `s2idle`.
- The strongest signal was suspend hanging until the runtime watchdog forced a
  reboot: `PM: suspend entry (s2idle)` without a matching resume, then next-boot
  watchdog reset evidence.
- Durable triage order:
  - test with runtime watchdog disabled
  - compare kernel lines (`6.18.13`, `6.19.3`)
  - only then vary NVIDIA stack details such as `reverseSync` and `supergfxd`
  - if the symptom changes to black screen, test `nvidia_wmi_ec_backlight`

## GNOME auto-lock

- GNOME lock settings were correct; the session was actively idle-inhibited.
- `mutter` held idle inhibitor flag `8`, matching Caffeine extension behavior.
- Most likely cause was the Caffeine GNOME extension, including its fullscreen
  inhibit path.
- Preferred fix was disabling Caffeine entirely or disabling its fullscreen
  trigger if the extension must remain installed.

## `amdxdna`

- Repeated `amdxdna` probe failures were traced to a firmware/driver protocol
  mismatch, not a display-driver crash.
- The mismatch reproduced across both observed kernel lines (`6.18.13` and
  `6.19.3`), so this was not a simple kernel-regression story.
- Immediate safe mitigation was to blacklist `amdxdna` on `pvl-a1` if the NPU
  was not needed.

## Practical interpretation

- Prioritize watchdog behavior before broader suspend speculation.
- Treat GNOME autolock failure as idle inhibition, not a settings bug.
- Treat `amdxdna` probe failures as likely unrelated noise unless the NPU is
  actually needed.

## Superseded notes

- `docs/ai/notes/pvl-a1-amdxdna-firmware-protocol-mismatch-2026-03-02.md`
- `docs/ai/notes/pvl-a1-gnome-autolock-not-triggering-2026-03-02.md`
- `docs/ai/notes/pvl-a1-suspend-resume-candidates-2026-03-02.md`
