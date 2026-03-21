# Nixbot Interrupt And Phase Short-Circuit Fix (2026-03)

## Scope

Document the `scripts/nixbot-deploy.sh` control-flow correction for user
interrupts and `--action all` phase gating.

## Findings

- `run_all_action` previously accumulated a failing status but still continued
  into later phases, so an earlier Terraform or host-phase failure could still
  allow later deploy or Terraform phases to run.
- Parallel host orchestration used `wait -n || true`, which treated an
  interrupted wait like a harmless completion and let the run continue after
  `Ctrl+C`.
- Phase status readers treated all nonzero host exit codes the same, so signal
  exits such as `130`/`143` were collapsed into ordinary host failures instead
  of aborting the run.

## Resolution

- `--action all` now short-circuits on the first failed phase:
  - Terraform dns/platform failure stops before host build/deploy
  - host failure stops before Terraform apps
  - Terraform apps still runs only if earlier phases succeeded
- Parallel build/deploy wait helpers now propagate signal exits instead of
  swallowing them.
- Build/deploy phase status handling now preserves `130`/`143` as interrupts so
  the run exits immediately instead of advancing to later phases.
- Exit cleanup now also terminates background jobs before removing temp state,
  so interrupted runs do not leave worker jobs driving forward after the parent
  starts teardown.

## Current interrupt semantics

- User interrupt stops the overall run.
- If deploy had already switched one or more hosts successfully before the
  interrupt, the run still attempts rollback for those already-switched hosts
  before exiting.
- Parallel deploy interrupt handling first terminates outstanding background
  deploy jobs, then collects completed wave statuses from status files so the
  rollback set includes hosts that finished before the interrupt was observed by
  the parent controller.
