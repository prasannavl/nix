# pvl-a1 Copilot Key keyd Regression

## Symptom

The ASUS TUF Gaming A14 FA401WV Copilot key on `pvl-a1` no longer behaves as
Right Control, although `lib/devices/asus-fa401wv.nix` still contains the keyd
mapping:

```nix
"leftmeta+leftshift+f23" = "layer(control)";
```

## Root cause

The mapping data is still evaluated, but keyd itself is disabled.

- The original device module enabled `services.keyd` directly.
- Commit `bb0f027e` (`Complete refactor`, 2026-01-18) moved the enablement into
  the imported `lib/keyd.nix` helper while retaining the device-specific
  mapping.
- Commit `955d58a7` (`Update keyd`, 2026-04-26) changed the helper to only add
  service hardening when `config.services.keyd.enable` is already true. It
  removed the shared `enable = true` assignment without adding a host-local
  assignment to the FA401WV module.
- Current evaluation therefore reports `services.keyd.enable = false` while
  retaining `services.keyd.keyboards.default`.

Live read-only inspection of `pvl-a1` on 2026-09-05 confirmed the evaluated
result: the current NixOS generation has no `keyd.service`, keyd executable, or
generated `/etc/keyd/default.conf`.

## Repair and validation boundary

The narrow declarative repair is to set `services.keyd.enable = true` in
`lib/devices/asus-fa401wv.nix`. Do not restore unconditional enablement in the
shared helper: its current conditional ownership is appropriate for hosts that
do not request keyd.

Before calling the repair complete:

1. Evaluate `nixosConfigurations.pvl-a1.config.services.keyd.enable` as true.
2. Verify the generated `default.conf` contains the existing keyboard ID and
   `leftmeta+leftshift+f23 = layer(control)` mapping.
3. Build the `pvl-a1` system closure.
4. After separately authorized deployment, confirm `keyd.service` is active and
   test the physical Copilot key as Right Control. If it still fails, inspect
   the live key event and device identifier; the absent service is already a
   sufficient cause for the current failure, but it does not prove firmware or
   kernel input identity has remained unchanged.
