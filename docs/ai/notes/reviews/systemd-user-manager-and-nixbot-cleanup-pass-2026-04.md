# systemd-user-manager and nixbot Cleanup Pass (2026-04)

## Scope

Focused cleanup and simplification in:

- `lib/systemd-user-manager/helper.sh`
- `lib/systemd-user-manager/default.nix`
- `pkgs/nixbot/nixbot.sh`

## Changes

- Deferred identity-driven `user@<uid>.service` restarts out of activation and
  into the normal dispatcher phase.
- Kept live reconciler progress, but made journal polling bounded so a slow
  `journalctl` call cannot wedge the wait/report loop.
- Simplified dispatcher restart/start control flow.
- Deduplicated stop-phase "preview vs stop" handling into one helper.
- Applied the same bounded journal polling cleanup to `nixbot`'s remote
  `systemd-user-manager` report path.
- Removed an unused `found` variable from the remote report helper.

## Rationale

- The switch path should block on unit state, not on unbounded journal queries.
- Old/new stop logic should stay easy to reason about and not duplicate the
  same stop action in multiple branches.
- The local helper and remote report path should follow the same operational
  model where practical.
