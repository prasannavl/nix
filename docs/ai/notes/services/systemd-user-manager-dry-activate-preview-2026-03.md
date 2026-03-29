# Systemd User Manager Dry-Activate Preview

## Context

`lib/systemd-user-manager.nix` originally skipped all reconcile work during
`dry-activate`. That kept dry activation non-mutating, but it also hid the
user-service actions that a real `switch` or `test` would perform.

For Podman stacks and other managed user services, that made `dry-activate` less
useful as an operator preview tool.

## Decision

Keep `dry-activate` non-mutating, but route it through the generated per-user
apply script in preview mode.

Preview mode:

- reads persisted managed-unit state
- inspects current user-unit state through `systemctl --user`
- logs the pre-actions, reconcile actions, drift-healing starts, post-actions,
  and ready-target start that would happen
- does not run transient actions
- does not start, restart, or reload user units
- does not daemon-reload user managers
- does not write new persisted stamps

## Outcome

- `dry-activate` now surfaces the actions `switch` or `test` would take
- preview remains non-destructive
- Podman stacks show lifecycle-tag and restart preview logs without touching the
  running services
