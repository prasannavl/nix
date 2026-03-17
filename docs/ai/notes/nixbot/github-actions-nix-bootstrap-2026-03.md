# Nixbot GitHub Actions Nix Bootstrap 2026-03

## Summary

Restored the `.github/workflows/nixbot.yaml` workflow after
`scripts/nixbot-deploy.sh` was changed to always re-exec inside `nix shell`.

## What Changed

- Added an explicit Nix installation step to the `nixbot` GitHub workflow before
  the `Remote action` step.
- Enabled `nix-command` and `flakes` in that workflow bootstrap step so the
  script's `nix shell --inputs-from <repo-root> ...` call works on the runner.

## Operational Notes

- GitHub-hosted `ubuntu-latest` runners do not provide `nix` by default, so the
  workflow must bootstrap it before invoking `scripts/nixbot-deploy.sh`.
- The failure signature for this mismatch is: `Required command not found: nix`.
- No secret file contents were read during this task.
