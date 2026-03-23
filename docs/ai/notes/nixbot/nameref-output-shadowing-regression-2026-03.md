# Nixbot Nameref Output Shadowing Regression (2026-03)

## Scope

Task-specific note for the March 23, 2026 snapshot regression after commit
`29750906cdcd9de6d0f6d085a709582d5d1e7b2d`.

## Root cause

- `prepare_deploy_context` was refactored from shared `PREP_*` globals to
  nameref outputs.
- The helper still declared scratch locals with the same names commonly used by
  callers for output variables: `ssh_target`, `nix_sshopts`, `age_identity_key`,
  and `ssh_opts`.
- In Bash, `local -n out_ref="ssh_target"` inside that helper binds to the
  helper's own local `ssh_target` when one exists, not the caller's local with
  the same name.
- As a result, callers such as `snapshot_host_generation` kept empty output
  variables and ran `ssh "" ...`, which surfaces as
  `ssh: Could not resolve
  hostname : Name or service not known`.

## Why it recurred

- The earlier March 2026 nameref audit mostly targeted two failure modes that
  had already produced visible symptoms:
  - helper-local nameref alias names colliding with caller variable names
  - nested helpers forwarding alias identifiers instead of the original target
    names
- This regression used function-prefixed nameref aliases, so it did not trip the
  prior circular-name-reference pattern.
- The missed gap was ordinary scratch locals inside a nameref helper reusing the
  same names as caller output variables.
- Durable audit rule: for nameref helpers, inspect both the nameref alias names
  and every non-nameref scratch local against likely caller output names.

## Durable fix

- Keep nameref output names and helper scratch locals disjoint.
- Prefer helper-private scratch names such as `resolved_*` for parsed values and
  `*_out_name` for forwarded output parameter names.
- When a nameref helper calls another nameref helper, pass the original output
  parameter names instead of the intermediate helper-local nameref alias names.
- For the deploy-context path specifically, prefer the simpler prepared-context
  string/array store (`PREP_*`) over scalar nameref outputs. The values are
  small, the call sites are tightly coupled, and the shared context avoids this
  recurring Bash by-reference footgun entirely.
- For other scalar-return helpers, prefer stdout plus caller-side capture
  (`var="$(helper ...)"` or multi-line `read`) over `local -n`. The current
  script now uses that style for deploy-result classification, snapshot-wave
  classification, Terraform backend/project context resolution, Terraform
  action-need evaluation, tofu var-file subcommand detection, SSH identity-file
  resolution, and run-context selection.

## Audit result

- The confirmed production regression was in `prepare_deploy_context`.
- `prepare_bootstrap_deploy_context` was tightened at the same time to follow
  the nested-helper rule and avoid future alias-forwarding surprises.
- A second audit removed the remaining obvious scalar nameref helpers in the
  deploy and Terraform paths.
- The remaining `local -n` usage in `pkgs/nixbot/nixbot.sh` is now primarily for
  arrays, counters, and summary aggregation where by-reference mutation is still
  the least awkward Bash option.
