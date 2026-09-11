# Shared Ollama Model Reconciler, 2026-09

## Decision

Pvl hosts use `lib/services/ollama.mkModelReconciler` instead of defining local
model-pull wrappers, retained oneshot units, and boot timers. The shared module
owns required-versus-retired validation, runtime environment construction,
asynchronous dispatch, worker timeouts, and managed-target attachment.

The dispatcher stays `active/exited` after successful dispatch so later NixOS
switches can restart it when its policy changes. The long-running pull remains
in a separate worker so normal managed-target startup is not blocked by model
downloads.

## Backend topology

The reconciler accepts these topology inputs:

- `readyTarget` optionally requires an active backend before dispatch;
- `backendServices` adds service ordering without starting those services and
  lets the helper skip API waiting when every declared backend is inactive;
- `ollamaUrls` supplies ordered API candidates for dual-backend hosts;
- `reconcileTriggers` preserves non-model triggers such as Podman Compose
  backend configuration changes.

At least one readiness target or backend service must be declared. Backend
services are worker `After=` dependencies, not `Wants=` dependencies. This is
also how the helper discovers which active Ollama services to `try-restart`
after the model store changes.

## Host mappings

- `pvl-x2` requires `pvl-ollama-ready.target` and observes `pvl-ollama.service`.
- `pvl-a1` requires the primary `pvl-ollama-ready.target`, observes both ROCm
  and optional NVIDIA services, and probes ports `11434` and `11435`.
- `pvl-l5` has no required readiness target because both backends are
  declaratively stopped. It observes both services and probes both ports, so a
  manually active backend can reconcile while the normal stopped state exits
  cleanly without starting either backend.

The legacy per-host boot timers are removed. `pvl-managed.target` now wants the
retained dispatcher directly.

## Version convergence

The official Ollama release page identifies `v0.34.0` as latest, and the
official Docker repository publishes matching `0.34.0` and `0.34.0-rocm` tags.
All Pvl Ollama compose images are pinned to those versioned tags: ROCm backends
use `0.34.0-rocm`, and NVIDIA backends use `0.34.0`.

## Validation

The shared helper and module checks pass. Full NixOS toplevel builds pass for
`pvl-a1`, `pvl-l5`, and `pvl-x2`, including the generated Podman Compose user
graph checks. Rendered unit inspection confirms the readiness and backend
dependency shapes above, a 3600-second worker timeout, both URLs on dual-backend
hosts, retained dispatchers, and no legacy timer links.

The cross-host refactor and fleet version convergence were built but not
deployed as part of this change.
