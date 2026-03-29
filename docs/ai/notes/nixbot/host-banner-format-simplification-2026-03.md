# Nixbot Host Banner Format Simplification

## Context

`nixbot` used phase-specific host banners such as `>>>>>>>>>>` for build and
`++++++++++` for deploy.

That made the output noisier without adding useful differentiation because the
phase label is already printed in the same line.

## Decision

Keep only two banner styles in `pkgs/nixbot/nixbot.sh`:

- `========== ... ==========` for main phase sections
- `---------- ... ----------` for host-stage banners

Host-stage output no longer varies its border characters by phase.
