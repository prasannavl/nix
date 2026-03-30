# Incus Machine Create Image Preflight

**Date**: 2026-03-31

## Summary

Make the per-guest Incus lifecycle helper verify or restore its exact declared
image alias immediately before `incus create`, instead of trusting deploy-time
unit orchestration alone.

## Context

Even after making `incus-images.service` rerunnable and making guest lifecycle
units require it, deploys still reached `incus create local:nixos-incus-base`
with the alias missing.

That means deploy-level orchestration is not a sufficient correctness boundary
for the guest create path. The hard prerequisite for `incus create` is not "the
image refresh unit was asked to run"; it is "the declared local alias exists
right now".

## Decision

- Refactor image refresh into a reusable helper function:
  `ensure_declared_image_present`.
- Keep `incus-images.service` as the deploy-wide image reconciliation pass.
- Also call the same helper from `machine_main` when a guest needs create or
  recreate.
- Pass the resolved per-instance image spec and `imageTag` into the guest unit
  environment so the create path can reconcile only its exact image input.

## Operational Effect

- The create path now has a just-in-time image preflight.
- A missing alias can be restored even if deploy-time unit ordering did not
  materialize the expected alias before the guest lifecycle unit ran.
- The preflight stays idempotent, so normal deploys do not repull or rebuild
  unless the image identity or `imageTag` changed, or the alias is actually
  missing.

## Source of Truth

- `lib/incus/helper.sh`
- `lib/incus/default.nix`
