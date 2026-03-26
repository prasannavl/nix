# Selective Cloudflare State Migration

## Goal

Move only a chosen subset of Cloudflare Terraform state from one backend to
another without mutating either backend by default.

## Tooling

- `scripts/archive/tf-plan-cloudflare-state-migration.sh`
- `scripts/archive/tf-plan-cloudflare-state-migration.py`

## Workflow

1. Generate a migration run with selectors such as:
   - `--zone gap3.ai`
   - `--zone llmug.com`
   - `--worker llmug-hello`
   - `--tunnel pvl-x2`
   - `--r2-bucket priyasuyash`
2. Review `docs/ai/runs/<session>/selected-manifest.json`.
3. Run `import-into-target.sh` against the target backend credentials/env.
4. Verify the target backend state and plans.
5. Run `remove-from-source.sh` against the source backend credentials/env.

## Selection Rules

- Direct selectors match by zone/domain strings, worker names, tunnel keys, R2
  bucket keys, or `--address-contains` text.
- Transitive expansion intentionally includes:
  - worker version/deployment/custom-domain resources for selected workers
  - R2 bucket-side resources for selected R2 buckets/custom domains
  - tunnel object/config/route resources for selected tunnel configs
  - zone-level platform resources for selected zones
- The migration planner records selection reasons per address so the transfer is
  auditable.

## Safety

- Planning mode only writes under `docs/ai/runs/`.
- It snapshots the current backend state for the selected projects but does not
  mutate state by itself.
- The generated import script is idempotent against the target backend: it skips
  addresses already present in state.
- The generated remove script is intentionally separate and should only run
  after target-side verification.
