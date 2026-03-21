# Nixbot Run Subcommand and Bare Usage Default (2026-03)

## Summary

- `nixbot` with no arguments now prints usage and exits successfully.
- The previous default deploy/Terraform workflow now lives behind
  `nixbot run ...`.
- `nixbot tofu ...` remains a separate local-only wrapper mode.

## Rationale

- A bare `nixbot` invocation should be non-destructive and self-describing.
- Making deploy behavior explicit avoids accidental full-run execution when the
  operator only wanted help or command discovery.
- The `run` subcommand keeps the existing deploy argument model intact while
  making top-level mode selection clearer.

## Follow-through

- Update internal command synthesis paths like bastion trigger and forced
  command bootstrap checks to emit `nixbot run ...`.
- Update workflow/package wrappers and operator-facing docs to use the `run`
  subcommand for deploy/Terraform examples.
