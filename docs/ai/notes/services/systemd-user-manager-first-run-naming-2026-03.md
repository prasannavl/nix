# systemd-user-manager First-Run Naming (2026-03)

## Context

`lib/systemd-user-manager.nix` previously used names that were too vague for
first-run behavior.

That wording was too vague:

- "initial" did not say initial what
- the managed-unit and action cases are similar but not identical
- the name should say what starts or runs, not just when

## Decision

Use explicit first-run names:

- `startOnFirstRun` for managed units
- `execOnFirstRun` for actions

## Outcome

- the unit and action cases now read explicitly instead of sharing one vague
  name
- the managed-unit names now line up as `startOnFirstRun` and `stopOnRemoval`
