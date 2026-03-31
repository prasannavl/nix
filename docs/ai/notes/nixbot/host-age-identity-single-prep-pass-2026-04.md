# host age identity Single Prep Pass (2026-04)

## Scope

This note records a `nixbot` deploy simplification in:

- `pkgs/nixbot/nixbot.sh`

## Problem

Deploys ran host age identity preparation twice before activation:

- an initial prep/inject pass
- a second activation-context prep pass that forcibly reinstalled the same key

The second forced reinstall was added as a workaround while activation-context
visibility was still unreliable, but the later probe/runtime fixes made that
extra overwrite unnecessary.

## Decision

Use a single host age identity prep pass at the activation-context preparation
point.

## Implementation

- Removed the initial pre-check prep call.
- Removed the `force_reinstall` plumbing from
  `inject_host_age_identity_key()` and `prepare_host_age_identity_for_deploy()`.
- The remaining prep pass still checks the current target file hash and injects
  only when the target is missing or mismatched.
- Activation-context visibility validation still runs immediately after that
  prep pass.

## Rationale

- The deploy path no longer does redundant age-identity target checks.
- Matching keys are still skipped safely.
- The single prep point keeps the age identity flow easier to reason about.
