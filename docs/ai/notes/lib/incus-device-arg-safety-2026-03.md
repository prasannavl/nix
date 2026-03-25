# Incus Device Arg Safety

## Context

A repo review found that `lib/incus.nix` built `incus config device add`
arguments by concatenating `key=value` strings into a shell scalar and then
expanding that scalar unquoted. That is only safe while every property stays
free of shell-sensitive characters and whitespace.

The same review also surfaced a few leftover dead bindings in the module:

- an unused `mkDeviceAddArgs` helper
- an unused `name` lambda argument in `mkUserMetadata`
- an unused `name` lambda argument in `mkDeviceTmpfiles`

## Decision

- Build `incus config device add` arguments with Bash arrays inside the service
  script.
- Iterate JSON keys with `mapfile` and `printf` instead of `for x in $(...)`
  where the values become shell arguments.
- Remove the dead helper and rename the intentionally unused lambda arguments to
  `_name`.

## Implementation

- `lib/incus.nix`
  - added shell helpers for JSON key iteration and safe device-add argument
    assembly
  - switched create-only and disk-device add paths to array-backed
    `incus config device add`
  - switched the surrounding key loops to `mapfile`
  - removed `mkDeviceAddArgs`
  - renamed the unused lambda arguments to `_name`

## Operational Effect

- Incus device properties now survive shell-sensitive values when the module
  invokes `incus config device add`.
- `deadnix` no longer reports the previous dead helper and unused lambda
  bindings in `lib/incus.nix`.
