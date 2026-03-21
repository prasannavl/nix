# Nameref audit and fixes - 2026-03

- Audited `scripts/nixbot-deploy.sh` for every bash nameref (`local -n`) helper
  after the deploy refactor surfaced runtime warnings such as
  `circular name reference`.
- Root cause: several helpers used local nameref identifiers like
  `failed_hosts_ref` and `success_hosts_ref`, and some callers passed variables
  with the same names. In bash this creates a self-referential nameref and
  triggers warnings or misbehavior.
- Convention adopted for future refactors: caller-side nameref target variables
  may use `*_ref`, but helper-local nameref aliases must use explicit direction,
  using `*_out_ref`, `*_in_ref`, or `*_inout_ref`.
- Fix applied: renamed helper-local nameref bindings to that private-directional
  convention (for example `failed_hosts_out_ref`, `build_hosts_in_ref`,
  `request_args_out_ref`) throughout the script while preserving the public call
  contract.
- Validation performed: `bash -n scripts/nixbot-deploy.sh` and
  `shellcheck scripts/nixbot-deploy.sh`.
