# Nixbot Deploy Env Prefix Rename (2026-03)

## Scope

Rename deploy-script variables and documented operator environment variables
from the legacy `DEPLOY_` prefix to `NIXBOT_`.

## Decision

- `scripts/nixbot.sh` now uses `NIXBOT_` for its deploy-scoped runtime
  variables, config defaults, and operator environment overrides.
- GitHub Actions wiring and nixbot-specific docs/playbooks should reference the
  new `NIXBOT_*` environment names.

## Notes

- The rename is intentionally mechanical for deploy-script-owned variables:
  `DEPLOY_*` became `NIXBOT_*`.
- Existing non-`DEPLOY_` names such as `AGE_KEY_FILE`,
  `NIXBOT_DEPLOY_IN_NIX_SHELL`, and Terraform provider variables remain
  unchanged.
