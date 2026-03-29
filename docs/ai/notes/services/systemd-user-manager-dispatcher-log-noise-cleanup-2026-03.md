# Systemd User Manager Dispatcher Log Noise Cleanup

## Context

The dispatcher journal output was slightly too verbose during deploy summaries.
For successful runs we want to keep:

- `dispatcher starting`
- reconciler progress lines
- `dispatcher finished`

We do not want the extra dispatcher line that names the reconciler service
before waiting, and the final dispatcher line does not need to repeat the
reconciler service name.

## Decision

Update `lib/systemd-user-manager/helper.sh` so `run_dispatcher_start`:

- removes `dispatcher starting <reconciler-service>`
- changes `dispatcher finished <reconciler-service>` to `dispatcher finished`

## Outcome

Successful deploy summaries stay behaviorally identical, but the dispatcher log
surface is cleaner and less repetitive.
