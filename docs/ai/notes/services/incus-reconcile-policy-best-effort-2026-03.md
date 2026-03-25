# Incus Reconcile Policy: Best Effort

## Context

`lib/incus.nix` gained activation-time reconcile so parent-host deploys could
recreate declared guests that had been manually deleted. The first version made
that reconcile path effectively strict: if a guest restart failed, parent-host
activation could fail too.

At the same time, `hosts/nixbot.nix` had short `wait = 3` delays for Incus
guests to soften later-wave snapshot retries in `nixbot`.

## Decision

- Default activation-time guest reconcile to `best-effort`.
- Support an explicit policy knob:
  - `off`
  - `best-effort`
  - `strict`
- Remove the Incus guest-specific `wait = 3` settings from `hosts/nixbot.nix`.

## Rationale

- Parent-host activation should still try to heal missing or stopped guests.
- A broken guest should not automatically block unrelated parent-host changes.
- Strict parent-host failure is still available when a host wants that policy.
- The earlier `nixbot` wait values were a guardrail for the previous behavior,
  not the desired steady-state deploy model.

## Implementation

- `lib/incus.nix` now defines
  `services.incusMachines.reconcileOnActivation`.
- Default is `"best-effort"`.
- In `best-effort` mode, activation logs guest reconcile failures and continues.
- In `strict` mode, activation aborts on guest reconcile failure.
- In `off` mode, no activation-time guest reconcile is run.
- `hosts/nixbot.nix` no longer sets `wait` for:
  - `llmug-rivendell`
  - `gap3-gondor`
  - `gap3-rivendell`

## Operational Effect

- Manually deleted or stopped guests are still retried automatically on the
  next parent-host activation.
- Parent-host activation is less brittle by default.
- Deploy sequencing still relies on the existing host dependency ordering, but
  no longer carries the Incus guest-specific retry delays.
