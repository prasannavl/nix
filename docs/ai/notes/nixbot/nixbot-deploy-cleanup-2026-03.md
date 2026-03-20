# Nixbot deploy cleanup - 2026-03

- Refactored `scripts/nixbot-deploy.sh` to pull repeated SSH context setup into
  `prepare_host_ssh_contexts`, so host key handling and remote-build host
  enrollment stay defined in one place.
- Added `resolve_ssh_identity_file` to centralize the repeated
  resolve-and-validate flow for deploy and bootstrap SSH keys.
- Collapsed top-level action dispatch into `run_deploy_request_action` so
  `run_requested_action` stays focused on run setup, summary handling, and exit
  status.
- Terraform/OpenTofu execution now runs through `run_with_combined_output` so
  GitHub Actions group markers and Terraform output share one stream and
  project-level groups do not leak stdout outside the group.
- `prepare_host_ssh_contexts` must use internal nameref variable names that do
  not match the callee argument names passed to `init_known_hosts_ssh_context`;
  reusing `ssh_opts_out`/`nix_sshopts_out` caused Bash circular-name-reference
  warnings during deploy-time snapshot/bootstrap preparation.
- Intended scope was cleanup only: no deploy ordering, bastion-trigger, or
  bootstrap semantics were changed.
