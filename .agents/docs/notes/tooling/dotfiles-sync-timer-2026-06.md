# Dotfiles Sync Timer 2026-06

`dotfiles-sync.timer` previously used only monotonic triggers:

- `OnStartupSec=0`
- `OnUnitActiveSec=1d`

On `pvl-l5`, the first startup-triggered clone failed on June 10, 2026 because
GitHub was not reachable yet. The service never reached a successful active
state, so `OnUnitActiveSec=1d` had no successful activation timestamp to anchor
the next daily firing. The timer stayed loaded and enabled, but live
`systemctl --user list-timers --all` showed `NEXT` as `-` and `Trigger: n/a`.

Use a calendar trigger for the daily sync instead. `OnCalendar=daily` schedules
future runs independently of whether the previous service invocation succeeded,
and `Persistent=true` is meaningful for calendar timers. Keep a short delayed
`OnStartupSec=30s` trigger so a fresh login or boot still attempts an early sync
without racing the first network setup as aggressively as `OnStartupSec=0`.
