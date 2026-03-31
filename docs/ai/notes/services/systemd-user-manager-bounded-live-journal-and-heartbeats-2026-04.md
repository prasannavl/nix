# systemd-user-manager Bounded Live Journal And Heartbeats (2026-04)

## Scope

This note records a dispatcher progress and hang fix in:

- `lib/systemd-user-manager/helper.sh`

## Problem

`wait_for_reconciler()` tried to provide live progress by polling `journalctl`
inside the same synchronous loop that waits for the reconciler unit to finish.

That design had two failure modes:

- if one `journalctl` poll became slow or wedged, the dispatcher looked frozen
  because both log replay and unit-state polling were blocked behind that call
- when the reconciler emitted little or no log output, the operator saw no
  visible progress even though the dispatcher was still waiting normally

## Decision

Keep live progress, but make journal polling bounded and keep unit-state waits
authoritative.

## Implementation

- Live journal polling remains in `wait_for_reconciler()`.
- Each `journalctl` poll is wrapped in `timeout` so a slow journal query cannot
  stall the dispatcher indefinitely.
- Journal polls are rate-limited instead of running every state-poll iteration.
- The dispatcher now emits a simple heartbeat line while still waiting for the
  reconciler, showing elapsed time.
- At completion, the dispatcher does one final cursor-based drain so only lines
  not yet shown are emitted.

## Rationale

- Operators keep seeing live reconciler logs when journald is responsive,
  without replaying already-emitted lines at the end.
- A bad journal query no longer blocks switch completion.
- Heartbeats cover the quiet-unit case where there may be little or no journal
  output to replay.
