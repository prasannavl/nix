# pvl WM Session Services

## Context

- `users/pvl/wm/` owns shared tiling-WM session packages and most Home Manager
  user services for the `pvl` desktop profile (Sway and Niri).
- Sway and Niri remain separate WM modules for compositor packages, portals, and
  config, but shared session daemons should not be duplicated there.
- `users/pvl/wm/services.nix` is the shared authority for WM session targets,
  the WM display-readiness targets, shared WM helper scripts, and the reusable
  `mkWmPostService` helper used by WM-adjacent user modules.
- `users/pvl/noctalia/` is WM-adjacent: it owns Noctalia settings and service,
  but must attach that service through the shared WM helper instead of
  re-declaring session-target wiring.
- `users/pvl/kanshi/` owns the kanshi package, config, and user service because
  the topology profiles are host-specific even though output defaults are
  shared.

## Decisions

- The common WM module owns `lxqt-policykit`, `swaybg`, and `portal-cleanup`.
  `noctalia-shell` is installed by the dedicated `users/pvl/noctalia/` module,
  while `kanshi.service` is split into its own user module.
  `portal-cleanup.service` is a `RemainAfterExit` oneshot attached to the
  compositor-specific WM ready targets: `ExecStart` stops/resets stale portal
  units and primes the GTK backend before ready services start; `ExecStop`
  stops/resets portal units when the active ready target is stopped by the
  compositor session ending.
- Shared Wayland desktop packages live in the common module when both Sway and
  Niri use the same tool, including terminal, launcher, lock, clipboard, XDG,
  audio, and backlight basics.
- Shared post-session services are installed under compositor-specific ready
  targets (`wm-session-ready-niri.target` and `wm-session-ready-sway.target`).
  The compositor signals display-readiness directly: Sway runs a
  `systemctl --user --no-block start wm-session-ready-sway.target` via `exec` in
  its generated config, and Niri runs the same command against its ready target
  via `spawn-at-startup`. The ready target `BindsTo` and `After` its matching
  session unit, so when the compositor fires the start, systemd itself orders
  the activation: if the session unit is not yet active, it is pulled in
  (BindsTo implies Requires) and the ready target waits via `After`. This is
  what replaces the earlier shell polling helper — no `is-active` probe, no
  bounded retry window, no races when Sway's wrapper
  `systemctl start sway-session.target` and the compositor `exec` run in
  parallel. `WantedBy = sessionUnit` is deliberately NOT used: the session unit
  can become active before the compositor has actually rendered, so auto-pulling
  the ready target off session activation would fire pre-display services too
  early. Compositor-driven start is the correct signal; systemd deps just remove
  the race. Each ready target must `BindsTo` only its own compositor session
  unit. Do not share a single ready target across both WMs with multi-unit
  `BindsTo`, because starting that target will pull in the other compositor
  session target and cross-couple Niri and Sway session state.
- The GTK portal backend is primed before `wm-session-ready.target` because
  `xdg-desktop-portal` can leave a stale D-Bus activation for
  `org.freedesktop.impl.portal.desktop.gtk` during compositor logout. If the
  next session lets `lxqt-policykit` trigger the portal core before the GTK
  backend owns its D-Bus name, GNOME apps block behind the old activation
  timeout.
- `portal-cleanup.service` has `After = sessionTargets` so that reverse-stop
  ordering runs its `ExecStop` BEFORE the compositor session unit shuts down on
  externally-initiated logout (GDM →
  `systemctl stop
  graphical-session.target`). This keeps the compositor alive
  long enough for the cleanup to stop `xdg-desktop-portal.service` (core) first,
  before any backend — so no client remains to trigger a dbus reactivation of
  the gtk backend when wayland eventually closes. `After=` alone does NOT help
  spontaneous compositor exits (crash, native quit bind), because by the time
  systemd marks the session unit inactive the compositor process and its wayland
  socket are already gone; any backend in-flight has already broken-piped and
  been dbus-reactivated under a dead display.
- System D-Bus uses `dbus-broker` (set via
  `services.dbus.implementation = "broker"` in `lib/systemd.nix` so every host
  gets it). The reference `dbus-daemon` did not propagate systemd start-failure
  cleanly to the pending activation slot for
  `org.freedesktop.impl.portal.desktop.gtk` during compositor teardown, so
  clients in the next session blocked for the full 120s `service_start_timeout`
  waiting on the stale slot. Evidence from pvl-x2: 18:13:54 gtk broken-pipe →
  dbus reactivate → `cannot open display
  :0` → exactly +120s later the "Failed
  to activate service 'gtk': timed out" line appears, with no fresh "Activating
  via systemd" in between. Broker resolves pending activation immediately on
  start-failure. Keep broker.
- The `portalCleanup` script used by `ExecStop` only runs `systemctl stop` on
  portal units — it does NOT run `reset-failed`. Earlier versions did, and that
  was the root cause of the post-sway/niri → GNOME hang: when
  `xdg-desktop-portal-gtk` failed to restart with `cannot open display :0`
  during compositor teardown, systemd marked the unit failed and would have
  reported the failure back to dbus-broker to resolve the pending activation
  slot. Our immediate `reset-failed` cleared the failed state before that
  notification was processed, suppressing the failure path. Dbus then waited the
  full 120s `service_start_timeout` on the stale activation before giving up,
  blocking every subsequent portal-dependent call from the GNOME session.
  Evidence in the journal: 17:16:17 broken-pipe + reactivation fail → 17:18:17
  `Failed to activate service
  'org.freedesktop.impl.portal.desktop.gtk': timed out
  (service_start_timeout=120000ms)`
  = exactly +120s. `reset-failed` is now only run by `preparePortals` against
  `portalBackendUnits` right before starting them, so every WM session starts
  from a fresh backend state without interfering with dbus activation
  bookkeeping during teardown.
- `portalCleanup` also owns `xdg-document-portal.service` teardown. After the
  pvl-x2 NixOS 26.05 transition, native Niri logout left `/run/user/1000/doc`
  mounted as `fuse.portal`; `xdg-document-portal.service` then waited on its
  `fusermount3` child until systemd's 90s stop timeout and entered failed state.
  The cleanup script now includes `xdg-document-portal.service` in the same
  portal stop set as the desktop portal units, so the existing session-teardown
  owner initiates document-portal stop earlier and explicitly. Keep this as a
  source fix rather than filtering the deploy health check.
- Compositor quit/exit actions should stay native. Do not override quit
  keybindings to run cleanup wrappers; cleanup belongs to the compositor-ready
  target lifecycle so it also runs for non-keybinding exits.
- The common wallpaper service uses `swaybg` with `data/backgrounds/sw.png`.
  Niri should not start `swaybg` from `spawn-at-startup`, and Sway should not
  use compositor-native `output bg` for this wallpaper.
- Shared Wayland services are owned by the compositor-ready targets, not
  directly by Sway/Niri session units. Ordering after `niri.service` or
  `sway-session.target` is not sufficient because those units can become active
  before `WAYLAND_DISPLAY` is usable for clients.
- Kanshi owns output profile switching. Global output defaults stay shared in
  `users/pvl/wm/outputs.nix`, and the kanshi module always installs the shared
  kanshi config and service when included.
- `users/pvl/kanshi/default.nix` is only the orchestrator. Generated defaults
  live in `config-defaults.nix`, host-specific profiles live in `profiles.nix`,
  and any shared profile text should be embedded directly in the orchestrator.
- Host-specific kanshi profiles are selected by `osConfig.networking.hostName`,
  but hosts without a profile still get the shared output-default config and the
  kanshi user service.
- Only `pvl-a1` currently has host-specific kanshi profiles. Other hosts can add
  shared profiles in the orchestrator or add their own host entry in
  `users/pvl/kanshi/profiles.nix` without changing the shared WM module.
- Sway now sets `defaultWorkspace = "workspace number 1"` explicitly so a
  laptop-only start lands on workspace 1 even if some later runtime client or
  session component creates or focuses workspace 10.

## Investigation Notes

- The generated Sway config does not contain a startup command, assignment, or
  workspace mapping that selects workspace 10 at startup.
- The remaining workspace-10 references are only the standard `Mod4+0` and
  `Mod4+Shift+0` keybindings.
- That means the workspace-10 start behavior is not explained by Home Manager
  config ordering; it is more likely caused by a runtime client or session
  component outside the static Sway config.
