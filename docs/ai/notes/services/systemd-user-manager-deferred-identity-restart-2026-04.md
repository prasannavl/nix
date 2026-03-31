# systemd-user-manager Deferred Identity Restart (2026-04)

## Scope

This note records the switch-time regression fix in:

- `lib/systemd-user-manager/default.nix`
- `lib/systemd-user-manager/helper.sh`

## Problem

The old-world stop activation helper compared old and new `identityStamp`
values and directly ran:

- `systemctl restart user@<uid>.service`

when a managed user's identity changed.

That restart happened inside `system.activationScripts`, before the main system
manager had reloaded the new generation's unit definitions. During deploys this
produced warnings such as:

- `The unit file ... of user@1000.service changed on disk. Run 'systemctl daemon-reload' ...`

and could leave switching stalled around the user-manager handoff.

## Decision

Keep old-world stop in activation, but defer identity-driven user-manager
restarts until the post-switch dispatcher phase.

## Implementation

- Activation old-stop still detects `identityStamp` changes.
- Instead of restarting `user@<uid>.service` immediately, it writes an
  ephemeral restart request marker under
  `/run/systemd-user-manager/restart-requests/`.
- `dispatcher-start` consumes that marker and performs the actual
  `systemctl restart user@<uid>.service` after the switch has reached the normal
  service start phase.
- If no marker exists, the dispatcher keeps the existing `systemctl start`
  behavior.

## Rationale

- The old/new diff still happens where both generations are visible.
- The actual restart now happens after systemd has already reloaded the new
  generation, matching the intended "stop old world now, start new world later"
  split.
- The restart handoff uses only ephemeral `/run` state and does not reintroduce
  persistent mutable state.

## Validation

- `bash -n lib/systemd-user-manager/helper.sh`
- `nix-instantiate --eval -E 'let pkgs = import <nixpkgs> {}; in 1'`
  was not used; validation stayed repo-local.
