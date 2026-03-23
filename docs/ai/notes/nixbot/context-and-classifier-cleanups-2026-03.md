# Nixbot Context And Classifier Cleanups (2026-03)

## Scope

Align helper names with responsibilities across run-context setup, snapshot-wave
handling, Terraform change detection, and tfvars materialization.

## Rules

- `prepare_*` helpers should prepare state, not emit user-facing logs.
- `resolve_*` or `evaluate_*` helpers should classify state and return metadata,
  not perform orchestration side effects.
- Secret-path discovery and decrypted-file materialization should be separate
  steps so callers can choose logging and side effects explicitly.
- Phase loops may orchestrate skips and rollbacks, but classification helpers
  should remain side-effect free.
