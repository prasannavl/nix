# Deployment Fixes Consolidated Notes (2026-03)

## Scope

Small deployment unblockers that do not need standalone long-lived notes.

## Incus build unblock

- `./scripts/nixbot-deploy.sh --hosts=pvl-x2` hit an `incus-6.22.0` `checkPhase`
  SIGBUS in sandboxed builds.
- Repository-side mitigation is:
  `virtualisation.incus.package = pkgs.incus.overrideAttrs (_: { doCheck = false; });`
- Rationale: package build output was usable while the test failure was
  intermittent and environment-specific.

## Superseded notes

- `docs/ai/notes/pvl-deployment-fixes-consolidated-2026-03.md`
