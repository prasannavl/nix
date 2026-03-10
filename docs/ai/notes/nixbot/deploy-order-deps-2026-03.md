# Nixbot Deploy Order Dependencies (2026-03)

## Scope

Minimal dependency-aware ordering for `scripts/nixbot-deploy.sh`.

## Decision

- `hosts/nixbot.nix` now accepts optional `hosts.<name>.deps = [ ... ];`.
- `scripts/nixbot-deploy.sh` topologically sorts the selected hosts before
  execution and derives deploy waves from that ordering.
- Dependencies only affect ordering among the selected hosts for a run.
- Explicit `--hosts a,b,c` input order is preserved as the stable tie-breaker
  when multiple hosts are otherwise ready.
- `--hosts all` still starts from flake host names, then applies dependency
  ordering on top.
- Build and deploy concurrency are controlled separately:
  - `DEPLOY_BUILD_JOBS` / `--build-jobs`
  - `DEPLOY_JOBS` / `--deploy-jobs`
- Bastion can be explicitly prioritized:
  - `DEPLOY_BASTION_FIRST` / `--bastion-first`
  - if enabled and selected, the bastion host is forced to the front of build
    ordering and into the first deploy wave
  - this override ignores the bastion host's own `deps`
  - other hosts still derive their order from `deps`

## Validation Rules

- Unknown selected hosts still fail validation.
- Unknown dependency names fail validation when the dependent host is selected.
- Cycles among selected hosts fail the run before build/deploy starts.

## Practical Effect

- The run still completes all selected builds before any deploy starts.
- Build can run across all selected hosts in parallel; it does not wait on
  dependency waves.
- Deploy is wave-based:
  - hosts whose selected dependencies are satisfied run in the current wave
  - dependent hosts wait for later waves
  - hosts in the same wave may still run in parallel up to `DEPLOY_JOBS`
- This is orchestration-only metadata; `flake show` remains unsuitable as a
  dependency-order source because `nixosConfigurations` is still an attrset.
