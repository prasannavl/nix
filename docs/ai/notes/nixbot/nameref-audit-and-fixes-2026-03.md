# Nameref audit and fixes - 2026-03

- Audited `scripts/nixbot-deploy.sh` for every bash nameref (`local -n`) helper
  after the deploy refactor surfaced runtime warnings such as
  `circular name reference`.
- Root cause: several helpers used local nameref identifiers like
  `failed_hosts_ref` and `success_hosts_ref`, and some callers passed variables
  with the same names. In bash this creates a self-referential nameref and
  triggers warnings or misbehavior.
- Convention adopted for future refactors: caller-side nameref target variables
  may use `*_ref`, but helper-local nameref aliases must not reuse the same
  caller-facing names. Use a distinct helper-local suffix plus explicit
  direction, such as `*_out_ref_local`, `*_in_ref_local`, or
  `*_inout_ref_local`.
- Fix applied: renamed helper-local nameref bindings to that
  helper-local-directional convention (for example
  `failed_hosts_out_ref_local`, `build_hosts_in_ref_local`,
  `request_args_out_ref_local`) throughout the script while preserving the
  public call contract.
- Validation performed: `bash -n scripts/nixbot-deploy.sh` and
  `shellcheck scripts/nixbot-deploy.sh`.
