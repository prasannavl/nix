# pvl-a1 Sway Client Scaling

## Context

- `pvl-a1` uses Sway at output scale `1.25`.
- The monitor/output setup already declares the fractional scale early, so
  remaining mild blur is no longer explained by late `kanshi` profile
  application.
- GNOME and Niri still appear crisper than Sway on the same panel.

## Findings

- GNOME enables Mutter `xwayland-native-scaling`, which improves XWayland
  rendering on HiDPI/fractional-scale setups.
- Niri integrates `xwayland-satellite`, whose upstream README states that for
  most GTK and Qt X11 apps it should scale them properly.
- Sway uses the traditional wlroots/XWayland path and does not have an
  equivalent XWayland crisp-scaling mechanism in this repo.
- The Sway session also did not export Wayland-preference environment variables
  that encourage apps with Wayland backends to avoid XWayland entirely.

## Root Cause

- The remaining blur in Sway is mainly client-path blur, not monitor-path blur.
- On fractional scales, X11 apps under Sway/XWayland are still bitmap-scaled in
  a way that is softer than native Wayland rendering.
- Because the Sway wrapper lacked Wayland-preference session exports, some apps
  that can run natively on Wayland were more likely to fall back to XWayland in
  Sway than in Niri or GNOME.

## Decision

- Keep the output-scale fix in place.
- Export Wayland-preference session variables from the NixOS Sway wrapper so
  display-manager launches and manual launches share the same client-backend
  policy.
- Treat any remaining blur after that change as an XWayland fractional-scaling
  limitation rather than a compositor startup or monitor-identity issue.

## Follow-up

- Prefer Wayland-native backends for Electron, Firefox, Qt, SDL, GTK, and winit
  applications.
- Shared output defaults now force `scale_filter nearest` for all configured
  displays to prefer sharpness over linear interpolation on Sway's fractional
  composition path.
- Shared output defaults also set `subpixel rgb` for both configured displays.
  This is an inferred best default from the current panel types; revisit if a
  panel-specific test shows clearer text with `bgr`, `vrgb`, `vbgr`, or `none`.
- If a specific app still shows `[X]` in Sway and still looks soft, the durable
  fix is that app's Wayland backend or a compositor/XWayland architecture with
  crisp fractional scaling for X11 clients, not further monitor tuning.
