# pvl WM Idle Lock

## Context

- `users/pvl/wm/default.nix` owns shared post-login services used by both the
  Sway and Niri desktop sessions.
- Both compositors already use the same `swaylock` command for explicit locking,
  but idle behavior was not yet configured in the shared WM layer.

## Decisions

- Idle management is owned by shared Home Manager user services
  `swayidle-sway.service` and `swayidle-niri.service`, each attached only to its
  matching compositor-ready target.
- Shared timeout policy lives in `users/pvl/wm/idle.nix` as a central
  `defaultTimeouts` attrset so battery and AC timings can be adjusted in one
  place without editing compositor-specific wiring.
- Both services use the same lock command:
  `swaylock -f -c 000000 --indicator-idle-visible`.
- Battery policy:
  lock after 10 minutes idle, power off monitors after 10 minutes plus 1 second,
  then suspend after 15 minutes idle.
- AC policy:
  lock after 15 minutes idle and power off monitors after 15 minutes plus
  1 second, with no automatic suspend.
- Resume powers monitors back on through the compositor-specific control path:
  `swaymsg "output * power on"` for Sway and
  `niri msg action power-on-monitors` for Niri.
- Power-source detection treats hosts without a battery as AC-powered so
  desktops follow the non-suspending policy by default.
- Existing manual lock shortcuts are aligned across both compositors:
  `Mod+Escape` locks and `Mod+Shift+Escape` toggles shortcut inhibition in
  both Sway and Niri.
