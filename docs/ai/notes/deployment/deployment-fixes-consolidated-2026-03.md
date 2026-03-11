# Deployment Fixes Consolidated Notes (2026-03)

## Scope

Small deployment unblockers that do not need standalone long-lived notes.

## Incus build unblock

- `./scripts/nixbot-deploy.sh --hosts=pvl-x2` hit an `incus-6.22.0`
  `checkPhase` SIGBUS in sandboxed builds.
- Durable mitigation is to disable that package check phase:
  `virtualisation.incus.package = pkgs.incus.overrideAttrs (_: { doCheck = false; });`
- Rationale: the built artifact was usable and the failure looked
  environment-specific, not like a deterministic package defect.

## Superseded notes

- `docs/ai/notes/pvl-deployment-fixes-consolidated-2026-03.md`
