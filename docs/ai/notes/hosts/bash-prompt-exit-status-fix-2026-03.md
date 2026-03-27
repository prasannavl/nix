# Bash Prompt Exit Status Fix

- Date: 2026-03-21
- Scope: `users/pvl/bash/bashrc.d/101-bash-prompt.sh`

## Summary

The prompt started rendering the exit-status command substitution literally, for
example:

`$(e="0"; [ "" = "0" ] || printf "[exit: %s]`

This came from the `f88b2f6` lint cleanup. The prompt fragment was rewritten as
`'\$(...)'`, which preserves the backslash in `PS1`. Bash therefore displayed
the text instead of evaluating the command substitution when drawing the prompt.

## Resolution

- Remove the backslash and keep the fragment single-quoted as `'$(...)'` so the
  command substitution is stored literally in `PS1` and evaluated at prompt
  render time.
- No behavior change beyond restoring the intended exit-status line.

## Follow-up Audit Of `f88b2f6`

- Reviewed the rest of commit `f88b2f6` for similar lint-driven semantic
  regressions.
- Confirmed the prompt bug was the only active shell/runtime regression found in
  that commit.
- `overlays/unstable-sys.nix` was also collapsed to
  `_inputs: _final: _prev:
  {}` in the same commit, but `overlays/default.nix`
  already had that overlay commented out before and after the commit, so this is
  dormant dead-code drift, not a live regression on current hosts.
- The remaining Nix refactors reviewed in the audit were structural regroupings
  (`boot = { ... };`, `services = { ... };`, `users = { ... };`, `inherit`
  rewrites) that preserved the same option paths.
