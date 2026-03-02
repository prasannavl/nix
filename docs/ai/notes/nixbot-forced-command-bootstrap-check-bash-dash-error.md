# Nixbot Forced-Command Bootstrap Check: `bash --` Root Cause Fix

## Context

- Observed during local deploy run on 2026-02-26:
  - `Forced-command bootstrap check failed for pvl-x2`
  - `bash: --: invalid option`
- This happened in `scripts/nixbot-deploy.sh` while running
  `check_bootstrap_via_forced_command`.

## Root Cause

- The forced-command bootstrap check sent raw option-style arguments over SSH
  (`--sha`, `--hosts`, ...).
- In non-forced-command shell paths, this can be interpreted by `bash -c` as an
  invocation option stream, producing:
  - `bash: --: invalid option`
- This failed before `nixbot-deploy.sh` argument parsing ran.

## Code Change

- File: `scripts/nixbot-deploy.sh`
- Function: `check_bootstrap_via_forced_command`
- Changed remote check invocation to execute script explicitly:
  - `/var/lib/nixbot/nixbot-deploy.sh ...`
  - This avoids leading-option command strings.
- Added SSH original-command normalization in `main()`:
  - Strip optional leading `--`
  - Strip optional leading `nixbot-deploy.sh` path token
  - This keeps forced-command parsing robust for both legacy and explicit-script
    invocations.

## Expected Behavior After Change

- Forced-command bootstrap checks run via an explicit script command and avoid
  bash option parsing failures.
- Deploy flow only falls back when there is a real auth/bootstrap failure.
