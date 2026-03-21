# Nameref audit and fixes - 2026-03

- Audited `scripts/nixbot.sh` for every bash nameref (`local -n`) helper after
  the deploy refactor surfaced runtime warnings such as
  `circular name reference`.
- Root cause: several helpers used local nameref identifiers like
  `failed_hosts_ref` and `success_hosts_ref`, and some callers passed variables
  with the same names. In bash this creates a self-referential nameref and
  triggers warnings or misbehavior.
- Convention adopted for future refactors: caller-side nameref target variables
  may use `*_ref`, but helper-local nameref aliases must not reuse the same
  caller-facing names. A plain directional suffix such as `*_out_ref` is not
  sufficient once one nameref helper calls another, because forwarding a local
  alias like `failed_hosts_out_ref` into a callee that declares the same alias
  recreates the circular reference.
- Stronger rule adopted after the follow-up deploy/build warnings:
  function-local nameref aliases should be function-specific when the helper is
  part of a nested nameref chain. Use a short deterministic function prefix: if
  the function name has multiple underscore-separated words, abbreviate it from
  first letters (for example `run_deploy_phase` -> `rdp`, `record_phase_status`
  -> `rps`); if it is a single word, use the whole function name. Do not add
  `_local` by default once the function prefix is present; only add `_local` if
  the shorter alias would collide with some other name already used in the
  current function or elsewhere in the script. Nested helpers should forward the
  original target-name parameters (`"$4"`, `"${10}"`, etc.) rather than
  forwarding their own local nameref alias identifiers.
- When a helper also needs `shift`, capture the target-name parameters into
  plain locals before shifting. Reading `"$6"`/`"$7"`/`"$8"` after `shift 8`
  forwards the wrong names and can silently break downstream nameref updates.
- If a helper only forwards an output slot to another helper and never reads or
  mutates the referenced value locally, keep that slot as a plain target-name
  string instead of creating an otherwise-unused nameref.
- Fix applied: normalized `scripts/nixbot.sh` end to end so every bash nameref
  helper now uses function-specific aliases, nested helpers forward the original
  target names instead of helper-local aliases, and `_local` is reserved only
  for collision-avoidance edge cases.
- Validation performed: `bash -n scripts/nixbot.sh` and
  `shellcheck scripts/nixbot.sh`.
