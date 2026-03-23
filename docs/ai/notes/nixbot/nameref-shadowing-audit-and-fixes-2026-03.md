# Nameref shadowing audit and fixes - 2026-03

## Summary

Audited and fixed all bash nameref (`local -n`) usage in `scripts/nixbot.sh`
after the deploy refactor surfaced `circular name reference` warnings at
runtime. The root cause was helper-local nameref identifiers colliding with
caller-supplied variable names, creating self-referential namerefs.

## Conventions adopted

### Function-specific nameref aliases

Helper-local nameref aliases must be function-specific to avoid collisions in
nested nameref chains. Use a short deterministic function prefix derived from
the function name:

- Multi-word: abbreviate from first letters (`run_deploy_phase` -> `rdp_`,
  `record_phase_status` -> `rps_`).
- Single-word: use the whole function name as prefix.

Only append `_local` if the shorter prefixed alias would collide with another
name already used in the same function or elsewhere in the script.

### Forward original target names, not aliases

Nested helpers must forward the original target-name parameters (`"$4"`,
`"${10}"`, etc.) rather than forwarding their own local nameref alias
identifiers. This prevents the callee from declaring a local alias that matches
the forwarded name.

### Capture target-name parameters before `shift`

When a helper uses `shift`, capture target-name positional parameters into plain
locals before shifting. Reading positional parameters after `shift` forwards the
wrong names and can silently break downstream nameref updates.

### Avoid scratch locals that shadow common caller output names

Nameref helpers must not declare scratch locals that collide with common
caller-supplied output variable names, even if the nameref alias itself is
uniquely named. For example, `resolve_tf_backend_context_for_project` had a
local `backend_kind` that shadowed the caller's identically named output
variable, causing `run_tf_action` to invoke `tofu init` without
`-backend-config=...` flags.

### Prefer plain strings for pass-through output slots

If a helper only forwards an output slot to another helper and never reads or
mutates the referenced value locally, keep that slot as a plain target-name
string instead of creating an otherwise-unused nameref.

## Fixes applied

- Normalized every nameref helper in `scripts/nixbot.sh` to use
  function-specific aliases: deploy/build helpers, utility, SSH, Terraform,
  summary, and request-hydration helpers.
- Fixed `resolve_tofu_auto_var_file_subcommand` where a local `subcommand`
  scratch variable could hide the caller output variable.
- Fixed `resolve_tf_backend_context_for_project` where a local `backend_kind`
  shadowed the caller target, leaving it empty and breaking backend
  configuration.
- Validation: `bash -n scripts/nixbot.sh` and `shellcheck scripts/nixbot.sh`.

## Superseded notes

- `docs/ai/notes/nixbot/nameref-audit-and-fixes-2026-03.md`
- `docs/ai/notes/nixbot/full-script-nameref-review-2026-03.md`
- `docs/ai/notes/nixbot/terraform-backend-context-nameref-fix-2026-03.md`
