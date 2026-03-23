# Nixbot Error Handling and Control Flow (2026-03)

## Exit status preservation

- Bash sets `$?` to the status of the negated condition in `if ! cmd; then ...`,
  so reading `$?` inside the `then` branch yields `0`, not the real failure
  code.
- Rule: never read `$?` after `if ! ...`. Prefer the inverted form:
  `if cmd; then ... else rc="$?"; ... fi`.
- Signal exit codes from `wait -n` (e.g. `130` for SIGINT, `143` for SIGTERM)
  must be preserved so interrupts short-circuit parallel waves correctly.

## Terraform failure propagation

- `run_tf_action` is called from an `if` condition via `run_tf_project_action`.
  Because Bash disables `set -e` inside functions evaluated by `if`, a failing
  `tofu init` could silently fall through to `plan`/`apply`, producing
  misleading follow-on errors (e.g. "Failed to load ... tfplan... as a plan
  file").
- Fix: test `tofu init`, `plan`, and `apply` explicitly inside `run_tf_action`
  and return non-zero on the first failure. This keeps reported errors aligned
  with the real root cause (e.g. backend reconfiguration required).
- After the multi-provider refactor, verify that `TF_PROJECT_NAMES` still
  includes all expected projects so `tf-platform` and `all` retain full phase
  coverage.

## Phase gating (`--action all`)

`run_all_action` short-circuits on the first failed phase:

1. Terraform dns/platform failure stops before host build/deploy.
2. Host build/deploy failure stops before Terraform apps.
3. Terraform apps runs only when all earlier phases succeeded.

## Interrupt semantics

- A user interrupt (Ctrl+C) stops the overall run.
- Parallel wait helpers propagate signal exits (`130`/`143`) instead of
  swallowing them; build/deploy status handling treats these as interrupts
  rather than ordinary host failures.
- Exit cleanup terminates background jobs before removing temp state, so
  interrupted runs do not leave workers running after the parent begins
  teardown.
- If deploy already switched one or more hosts before the interrupt, the run
  attempts rollback for those hosts before exiting.
- Parallel deploy interrupt handling first terminates outstanding background
  deploy jobs, then collects completed wave statuses from status files so the
  rollback set includes hosts that finished before the interrupt was observed.

## Superseded notes

- `exit-status-negation-fix-2026-03.md`
- `interrupt-and-phase-short-circuit-2026-03.md`
- `terraform-init-failure-propagation-2026-03.md`
