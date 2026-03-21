# Nixbot Script Entrypoint Rename (2026-03)

## Scope

Rename the deploy/orchestration entrypoint from `scripts/nixbot-deploy.sh` to
`scripts/nixbot.sh`, including the installed bastion wrapper path.

## Decision

- The canonical repo entrypoint is now `scripts/nixbot.sh`.
- The installed bastion-side wrapper path is now `/var/lib/nixbot/nixbot.sh`.
- References in workflows, docs, playbooks, and package wrappers should use the
  new script name.
