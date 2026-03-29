# systemd-user-manager Stable-State Backoff (2026-03)

- `lib/systemd-user-manager.nix` now waits for user-unit `ActiveState` with a
  bounded progressive backoff instead of a fixed 0.5s polling loop.
- The current schedule is `0.5s`, `1s`, `2s`, then `5s` for later attempts.
- This reduces deploy-time polling noise for long user-unit startups without
  changing the fail-closed timeout behavior.
- Call sites now handle `unit_stable_state` failure explicitly, so a timeout
  reports the timeout directly instead of collapsing into an empty
  `unexpected stable ActiveState` message.
- This cleanup was prompted by the March 29 `pvl-x2` recovery, where broken
  Podman user units left stale `activating` state behind and the previous error
  path obscured the real reason for reconcile failure.
