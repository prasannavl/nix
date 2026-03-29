# Nixbot Systemd User Manager Deploy Summary Streaming

## Context

The inline `systemd-user-manager` deploy summary was buffered twice:

- `nixbot` captured the entire remote report into a shell variable before
  printing anything.
- the remote report helper waited for dispatcher terminal state and only then
  dumped the reconciler journal.

That made the deploy appear stuck until the full `systemd-user-manager` log
block was complete.

## Decision

Update `pkgs/nixbot/nixbot.sh` so the post-deploy report streams incrementally:

- `print_deploy_systemd_user_manager_report` now streams remote stdout directly
  instead of capturing it first.
- the remote helper now tails new dispatcher and reconciler invocation logs in a
  polling loop while the dispatcher is still running.
- dispatcher lines are filtered to dispatcher-only messages so the final
  dispatcher-side reconciler journal replay does not duplicate the directly
  streamed reconciler output.

## Outcome

Successful deploys now show `systemd-user-manager` progress as it happens
instead of pausing until the entire report is ready. The final dispatcher status
line is still emitted after the unit reaches terminal state.
