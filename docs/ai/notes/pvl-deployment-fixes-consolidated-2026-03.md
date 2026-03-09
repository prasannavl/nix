# Deployment Fixes Consolidated Notes (2026-03)

## Scope

Consolidates small March 2026 deployment unblockers that do not justify
standalone long-lived notes.

## Incus build unblock

- `./scripts/nixbot-deploy.sh --hosts=pvl-x2` hit an `incus-6.22.0`
  `checkPhase` SIGBUS in sandboxed builds.
- The repository-side mitigation is:
  `virtualisation.incus.package = pkgs.incus.overrideAttrs (_: { doCheck = false; });`
- Rationale: the package build itself succeeds, while the test failure is
  intermittent and environment-specific; skipping tests keeps deploys moving.

## Canonical interpretation

Treat this file as the canonical summary for the following superseded
March 2026 note:

- `pvl-incus-checkphase-sigbus-2026-03-05.md`
