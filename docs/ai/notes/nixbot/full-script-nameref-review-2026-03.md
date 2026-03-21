# Full script nameref review

Date: 2026-03-21

- Reviewed `scripts/nixbot.sh` end to end for helper-local bash nameref safety,
  naming consistency, and the specific shadowing failure mode where a
  helper-local scratch variable collides with a caller output name.
- Normalized the remaining pre-convention helper-local nameref aliases first to
  a directional `*_out_ref`/`*_in_ref`/`*_inout_ref` scheme, then tightened the
  nested-helper cases to short function-prefixed aliases where the directional
  name alone still left collision risk.
- Follow-up finding from live bastion runs: the directional suffix scheme alone
  was still too weak for nested nameref helpers, because forwarding a local
  alias into another helper can still collide if the callee declares the same
  alias name. Durable rule: use short function-specific nameref aliases in
  nested helpers (`rdp_*`, `rps_*`, etc.) and forward the original target-name
  parameters, not the local alias identifiers. Reserve `_local` only for the
  cases where the shorter function-prefixed alias would otherwise collide with
  another name already in use.
- Applied that rule across the full script, not only the original deploy/build
  hot spots, so utility, SSH, Terraform, summary, and request-hydration helpers
  now use the same collision-avoidance pattern.
- Fixed a second real shadowing hazard in
  `resolve_tofu_auto_var_file_subcommand`, where a local `subcommand` scratch
  variable could hide the caller output variable when the caller also used the
  name `subcommand`.
- Retained behavior while simplifying the audit surface: helper-local nameref
  bindings are now easier to grep and review consistently across the script.
- Validation performed:
  - `bash -n scripts/nixbot.sh`
  - `shellcheck scripts/nixbot.sh`
  - source-level checks confirming:
    - `resolve_tofu_auto_var_file_subcommand subcommand ...` writes back to the
      caller variable
    - `resolve_tf_backend_context_for_project` writes backend context back to
      caller variables when passed common names like `backend_kind`
