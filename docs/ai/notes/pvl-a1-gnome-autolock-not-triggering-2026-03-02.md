# pvl-a1 GNOME auto-lock not triggering (2026-03-02)

## Context

- User reported GNOME session for `pvl` does not auto-lock after configured idle
  timeout on AC power.
- Battery suspend behavior still works as expected.

## Findings

- Session and lock settings are correctly configured for lock-on-idle:
  - `org.gnome.desktop.session idle-delay = 480` (8 minutes)
  - `org.gnome.desktop.screensaver lock-enabled = true`
  - `org.gnome.desktop.screensaver lock-delay = 0`
  - `org.gnome.desktop.screensaver idle-activation-enabled = true`
- Power behavior is intentionally configured to avoid AC suspend:
  - `org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type = 'nothing'`
  - `org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type = 'suspend'`
- GNOME session is actively idle-inhibited:
  - `org.gnome.SessionManager.IsInhibited(8) = true` (idle inhibition active)
  - Inhibitors include:
    - `mutter` with reason `idle-inhibit` and flags `8`
    - Chrome with reason `Playing audio` and flags `4` (suspend only)
- Nix config enables Caffeine GNOME extension:
  - `users/pvl/gnome/extensions.nix` includes `pkgs.gnomeExtensions.caffeine`
    with `enable = true`.
- Caffeine extension logic can issue idle inhibition (flag `8`) for reasons
  including fullscreen mode (`enable-fullscreen` default is `true`).

## Conclusion

- Auto-lock is not failing due to lock timeout settings; it is being bypassed by
  an active GNOME idle inhibitor.
- The inhibitor path matches Caffeine extension behavior
  (`mutter: idle-inhibit`), making Caffeine the likely source.
- Most likely trigger is Caffeine active state (manual toggle and/or
  fullscreen-triggered inhibit).

## Suggested fixes

- Preferred: disable Caffeine extension in Nix
  (`users/pvl/gnome/extensions.nix`) if auto-lock should always work.
- Alternative: keep Caffeine but disable its fullscreen-trigger behavior
  (`enable-fullscreen = false`) and only use manual toggles when needed.
- Diagnostic quick check in live session:
  - Toggle Caffeine off in GNOME quick settings and confirm `IsInhibited(8)`
    becomes `false`.
