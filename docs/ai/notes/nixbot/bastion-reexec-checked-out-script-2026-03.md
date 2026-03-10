# Nixbot Bastion Re-exec of Checked-out Script (2026-03)

## Problem

The bastion forced-command entrypoint runs `/var/lib/nixbot/nixbot-deploy.sh`.
That script fetches and checks out the requested `--sha`, but the current shell
process keeps executing the already-installed bastion copy. Repo changes in
`scripts/nixbot-deploy.sh` therefore do not affect that run until bastion itself
is redeployed.

## Decision

- Add explicit opt-in control:
  - CLI: `--use-repo-script`
  - env: `DEPLOY_USE_REPO_SCRIPT=1`
- After `ensure_repo_for_sha`, re-exec the checked-out repo copy at
  `${REPO_PATH}/scripts/nixbot-deploy.sh` only when that opt-in is enabled and
  the current script path is not already that file.
- Guard with `NIXBOT_REEXECED_FROM_REPO=1` to avoid loops.

## Effect

- Default bastion-trigger runs remain pinned to the installed
  `/var/lib/nixbot/nixbot-deploy.sh` wrapper.
- Operators can still opt into running the checked-out repo script for
  controlled testing or emergency rollouts.
- CI should leave this disabled for security: otherwise the forced-command path
  would execute freshly fetched repo script logic before bastion is updated to
  that trusted version. Keep the two-phase model: deploy wrapper/script changes
  first, then rely on them in later runs.
