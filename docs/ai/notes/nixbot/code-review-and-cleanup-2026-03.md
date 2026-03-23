# Nixbot Code Review and Cleanup (2026-03)

## Scope

Full-script review and cleanup of `pkgs/nixbot/nixbot.sh` (~5500 lines) across
two passes: subprocess reduction / deduplication, then correctness / dead-code /
style.

## Changes

### jq call consolidation

Collapsed many sequential jq invocations into single calls throughout the
script:

- `resolve_deploy_target`: 9 separate jq calls reduced to 1. A local `fb`
  (fallback) function inside jq handles empty-to-default conversion.
- `prepare_deploy_context` target_info parsing: 8 calls reduced to 1, fields
  read line-by-line via `read -r`.
- `init_deploy_settings`: 8 calls reduced to 2 (1 for scalars via `read -r`, 1
  for the hosts JSON object).
- `select_hosts_json`: replaced `jq -R . | jq -s .` pipe with single
  `jq -Rn '[inputs | select(length > 0)]'`.

### Extract `_try_abort_wave` helper in `run_deploy_phase`

Four identical 10-line `abort_deploy_on_signal` call blocks extracted into an
inner function `_try_abort_wave`. It captures the fixed context variables
(`_success_hosts_out_name`, `_failed_hosts_out_name`, `snapshot_dir`, etc.) from
enclosing scope and forwards only the varying exit code.

Also replaced raw `${10}` / `${13}` positional references with named locals.

### Extract `host_predecessors_for` helper

`order_selected_hosts_json` and `selected_host_levels_json` both had duplicate
loops over `host_dependencies_for` + `host_ordering_after_for`. Introduced
`host_predecessors_for` (single jq: `(.deps // []) + (.after // [])`) and
collapsed both pairs into one loop each.

### Bug fix: `check_remote_cmd` double array construction

`check_bootstrap_via_forced_command` built `check_remote_cmd` unconditionally
then rebuilt it from scratch when `check_sha` was non-empty. Fixed to build
incrementally with `+=`.

### Simplify `resolve_tf_change_base_ref`

Eliminated redundant double `git rev-parse` (one to check, one to capture).
Collapsed to single assignment with `|| return 1`. Combined `TF_CHANGE_BASE_REF`
validation and capture into one step.

### Simplify secret-loading functions

`load_cloudflare_tf_backend_runtime_secrets` and
`load_gcp_tf_backend_runtime_secrets`: replaced manual associative-array loops
with direct calls to existing `load_env_value_from_secret_file_if_unset` helper.

### Minor simplifications

- `emit_normalized_hosts`: folded `sed '/^$/d'` into the existing awk
  (`NF && !seen[$0]++`).
- `should_ask_sudo_password`: replaced `if ... return 0; fi; return 1` with
  direct test expression.
- `is_github_actions_log_mode`, `should_discover_decrypt_keys`: removed
  unnecessary bare `return` after `[ test ]` inside `case` arms (the `;;`
  already propagates the test exit status).
- `tofu_args_have_explicit_vars`, `tofu_args_have_explicit_backend_config`,
  `deps_action_help_requested`: removed unnecessary `$@`-to-array copies;
  iterate `$@` or use `$1` / `$#` directly.

### Style: one `local` declaration per line

Split all multi-variable `local` declarations onto separate lines throughout the
script (both initialized and uninitialized forms).

## Decisions and patterns

### Line-per-field `read -r` for jq output

Used line-per-field `read -r` from a single jq array output instead of `@tsv`.
Avoids escaping issues with fields that could contain tabs (e.g., `knownHosts`).

### Inner functions for scoped helpers

Chose bash inner functions (e.g., `_try_abort_wave`) when all arguments come
from the enclosing function's scope. Avoids 10+ positional parameter forwarding.

### `if cmd; then : else phase_rc=$?` pattern kept

Under `set -e`, this is the correct idiom to capture a non-zero exit code.
`if ! cmd; then phase_rc=$?` does not work because `$?` is always 0 inside
`if !`.

### `after` ordering not validated for execution policies

`after` is a soft ordering constraint. Ordering after a skipped host is valid
(the constraint is ignored when the target is absent from the selection). No
validation added in `validate_selected_host_execution_policies`.

### `abort_deploy_on_signal` return-value flow verified

If non-signal: returns 1 (deploy-wave-failed path). If signal:
`handle_deploy_interrupt` returns the signal code (130/143), which propagates
through `phase_rc`. Correct as-is.

### 14-parameter nameref functions kept

`host_final_status` and `set_run_summary_host_state` use 14 positional
parameters with nameref indirection. Verbose but functional; refactoring to
globals or structs would be invasive with unclear benefit.

## Superseded notes

- `docs/ai/notes/nixbot/cleanup-and-simplification-pass-2026-03.md`
- `docs/ai/notes/nixbot/fresh-review-and-dedup-2026-03.md`
