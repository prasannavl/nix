# systemd-user-manager Inactive-Action Naming (2026-03)

## Context

`lib/systemd-user-manager.nix` previously exposed inactive-unit action behavior
through names that were too implicit.

That naming was too implicit:

- the old naming did not say which unit being inactive mattered
- `run` did not make it obvious that the action still runs while the observed
  unit stays inactive
- `start` did not make it obvious which unit gets started first

This was especially confusing in bridges that separate `observeUnit` from
`changeUnit`.

## Decision

Rename the action option to `observeUnitInactiveAction` and use clearer enum
values:

- `fail`
- `run-action`
- `start-change-unit`

## Outcome

- action configuration reads directly from the bridge model
- the option now says which inactive state matters: `observeUnit`
- the enum values now say whether the action runs anyway or starts
  `changeUnit` first
