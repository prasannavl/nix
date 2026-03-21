# TODO

## Nixbot PR Dry Runs

Why:

- Today, trusted bastion-triggered deploy operators can run arbitrary reachable
  SHAs, but the workflow for PR dry runs is not yet set up as a clear,
  documented, and intentionally scoped path.
- Worktree isolation solved the shared-checkout/concurrency problem, but the CI
  workflow, secret model, and review expectations for PR dry runs still need to
  be defined explicitly.

- [x] Isolate `nixbot-deploy` runs into per-run Git worktrees so bastion can
      evaluate/deploy committed state without mutating the persistent repo root.
      Dependency: none.

- [ ] Allow PR-triggered `nixbot` dry runs in GitHub Actions while keeping the
      trusted bastion deploy path and review/security expectations explicit.
      Depends on:
  - per-run Git worktree isolation in `nixbot-deploy`
  - documented nixbot trust model for bastion-triggered arbitrary SHA runs

- [ ] Define a reduced-trust PR dry-run credential model if PR dry runs should
      not have the same secret/key access as trusted bastion-triggered deploy
      operators. Depends on:
  - PR-triggered dry-run workflow design
  - environment-scoped secrets selection support

## Environment-Scoped Secrets

Why:

- Some remaining deployment/security work depends on being able to select a
  different set of secrets for different environments without inventing a
  parallel deploy code path.
- The goal is to keep deploy/runtime behavior uniform while making the chosen
  secret set obvious and mechanically selected.

- [ ] Add multiple environment secrets support so the same deploy/runtime code
      paths can select the correct secret set automatically. Depends on: none.

- [ ] Choose the top-level selection model for multi-environment secrets.
      Options to decide:
  - different directories selected automatically
  - shared directories with environment-specific file suffixes Depends on:
  - multiple environment secrets support

## Cloudflare Credential Scope

Why:

- Today, the Cloudflare automation effectively relies on one credential scope
  broad enough to satisfy DNS, platform, and apps phases together.
- That is convenient, but it means the blast radius of one credential is larger
  than necessary.
- Splitting credentials by phase would let DNS, platform, and apps use only the
  permissions they actually need, and it would also make future reduced-trust
  dry-run designs easier.

- [ ] Split Cloudflare DNS / platform / apps credentials so each phase uses the
      minimum access it needs and blast radius is reduced. Depends on:
  - environment-scoped secrets support
  - PR dry-run credential model, if dry runs should use reduced-trust keys
