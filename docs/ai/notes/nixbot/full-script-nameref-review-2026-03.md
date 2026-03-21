# Full script nameref review

Date: 2026-03-21

- Reviewed `scripts/nixbot-deploy.sh` end to end for helper-local bash nameref
  safety, naming consistency, and the specific shadowing failure mode where a
  helper-local scratch variable collides with a caller output name.
- Normalized the remaining pre-convention helper-local nameref aliases to the
  established `*_out_ref_local`, `*_in_ref_local`, and `*_inout_ref_local`
  scheme.
- Fixed a second real shadowing hazard in
  `resolve_tofu_auto_var_file_subcommand`, where a local `subcommand` scratch
  variable could hide the caller output variable when the caller also used the
  name `subcommand`.
- Retained behavior while simplifying the audit surface: helper-local nameref
  bindings are now easier to grep and review consistently across the script.
- Validation performed:
  - `bash -n scripts/nixbot-deploy.sh`
  - `shellcheck scripts/nixbot-deploy.sh`
  - source-level checks confirming:
    - `resolve_tofu_auto_var_file_subcommand subcommand ...` writes back to the
      caller variable
    - `resolve_tf_backend_context_for_project` writes backend context back to
      caller variables when passed common names like `backend_kind`
