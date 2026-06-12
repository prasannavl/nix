# Nixbot Deploy Host Command Path

Date: 2026-06-12

## Decision

Nixbot CI/deploy-capable hosts install `pkgs.nixbot` into the system profile.
Delegated activation invokes:

```text
/run/current-system/sw/bin/nixbot
```

instead of a bare `nixbot`.

## Reason

Remote deploy-host activation connects with the normal deploy key, not the CI
forced-command key. The CI authorized key can reference an absolute
`pkgs.nixbot` store path, but that does not put `nixbot` on the normal deploy
user's non-interactive SSH `PATH`.

The deploy host should expose a stable command path through the current system
profile, and the caller should use that absolute path so activation does not
depend on shell startup or PATH behavior.
