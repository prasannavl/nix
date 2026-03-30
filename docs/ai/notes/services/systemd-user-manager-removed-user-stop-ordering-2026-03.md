# systemd-user-manager Removed User Stop Ordering

**Date**: 2026-03-31

## Summary

Split `systemd-user-manager` activation into a real two-phase layout so old
managed user units are stopped before the `users` activation phase removes the
underlying account, while dry-activation preview stays after `users`.

## Context

The module already had a conceptual split between:

- old-generation stop logic in the activation helper
- new-generation start/reconcile via dispatcher services

But the activation hook that called the stop logic had `deps = ["users"]`, so
the stop pass actually ran after account removal. When a managed user was
deleted from the system, the helper could no longer resolve the old account and
logged `stop skipped: account unavailable`.

## Decision

- Add a pre-`users` activation snippet for `switch` and `test` that runs only
  the old-generation stop phase.
- Keep dry-activation preview as a separate post-`users` snippet, since it does
  not mutate live state and still benefits from the evaluated new-world user
  metadata.
- Keep new-generation start/reconcile owned by the generated dispatcher
  services, not by activation.

## Operational Effect

- Removed managed users can have their old user units stopped while the account
  still exists.
- The activation path no longer depends on post-removal lookups for old-user
  cleanup.
- Dry-activation preview behavior remains unchanged in effect, but is now
  explicitly separated from the live stop path.

## Source of Truth

- `lib/systemd-user-manager/default.nix`
- `lib/systemd-user-manager/helper.sh`
