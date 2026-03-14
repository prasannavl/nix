# Nixbot All Action and TF Change Gating (2026-03)

Updated `nixbot` so the deploy script is the only place that decides whether the
OpenTofu phase should run.

## Changes

- Extended `scripts/nixbot-deploy.sh` with a new default `--action all`.
- `all` now means:
  - run `--action tf` behavior first only when TF-related files changed
  - then continue with the normal host build + deploy flow
- `--dry` remains a flag:
  - `all --dry` runs TF plan-only when needed, then build + deploy dry-run
  - `deploy --dry` keeps the host deploy dry-run behavior
  - `tf --dry` runs TF plan-only
- `--force` is the only public override for TF unchanged skips.
- TF change detection now lives only in `scripts/nixbot-deploy.sh` and checks:
  - `tf/**`
  - the repo-managed encrypted Cloudflare OpenTofu secret inputs under
    `data/secrets/cloudflare/*.age`
- Follow-up cleanup refactored `scripts/nixbot-deploy.sh` to:
  - centralize force/dry/prefix state transitions in small helpers
  - normalize `all` into a deploy-style host action internally
  - collapse repeated bootstrap-ready and fallback-target branches
  - reuse shared remote temp-file/install helpers for bootstrap keys and age
    identity installation
  - resolve the TF diff base only after `git fetch --prune origin`, preferring
    `refs/remotes/origin/HEAD` so `--sha` runs compare against fresh remote
    default-branch state instead of a stale or hard-coded `origin/master`
  - keep `PREP_*` as the deploy-context store, but isolate its use through
    small phase helpers and one local-materialization helper so per-host
    snapshot/deploy/rollback paths stop reaching into those globals directly
  - consolidate deploy-context reset and SSH option assembly into small helpers
    so `prepare_deploy_context` has one reset point and avoids duplicating the
    primary/bootstrap `known_hosts` and identity-option wiring
- `.github/workflows/nixbot.yaml` exposes manual inputs:
  - `action = all|build|deploy|tf`
  - `dry = true|false`
- The separate TF-only workflow was removed in favor of the single `nixbot`
  workflow plus script-side gating.

## Intent

- Keep GitHub Actions simple and avoid duplicating TF change-detection logic in
  workflow YAML.
- Ensure bastion-triggered runs, local runs, and CI all use the same TF gating
  decision path.
