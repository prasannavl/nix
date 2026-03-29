# Nixbot Systemd User Manager Deploy Summary Header Cleanup

## Context

The inline `systemd-user-manager` deploy summary already starts with the
dispatcher unit status line, for example:

- `systemd-user-manager-dispatcher-pvl.service: ok (...)`

That makes the extra standalone header line:

- `[systemd-user-manager]`

redundant noise.

## Decision

Update `pkgs/nixbot/nixbot.sh` so the deploy summary prints only the dispatcher
status block returned by the remote report helper, without prepending an extra
`[systemd-user-manager]` header.

## Outcome

Successful deploy output stays grouped and readable, but loses one unnecessary
line at the start of each `systemd-user-manager` report block.
