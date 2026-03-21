# Nixbot Action-Based CLI and Bare Usage Default (2026-03)

## Summary

- `nixbot` with no arguments now prints usage and exits successfully.
- `nixbot run` now means the full workflow that previously lived behind the
  implicit default and then the temporary `run --action all` form.
- Dependency setup is now action-based too: `deps` replaces the old
  `--ensure-deps` shortcut, and `check-deps` verifies the current environment
  without re-exec.
- Deploy/Terraform modes are now top-level actions: `deploy`, `build`, `tf`,
  `tf-dns`, `tf-platform`, `tf-apps`, `tf/<project>`, and `check-bootstrap`.
- `nixbot tofu ...` remains a separate local-only wrapper mode.

## Rationale

- A bare `nixbot` invocation should be non-destructive and self-describing.
- Promoting operational modes to top-level actions removes the extra `--action`
  indirection from the CLI and makes bastion-triggered commands shorter and
  clearer.
- Promoting dependency setup to `deps` and `check-deps` makes the difference
  between "enter the pinned runtime shell" and "verify the current shell"
  explicit.
- `run` remains as the explicit full-workflow entrypoint, so the old default
  behavior is still available without overloading bare invocation.

## Follow-through

- Update internal action synthesis paths like bastion trigger and forced command
  bootstrap checks to emit the direct top-level action form.
- Update workflow/package wrappers and operator-facing docs to use direct
  commands like `nixbot deploy`, `nixbot tf-apps`, and `nixbot deps`.
