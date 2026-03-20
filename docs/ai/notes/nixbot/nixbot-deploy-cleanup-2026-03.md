# Nixbot deploy cleanup - 2026-03

- Refactored `scripts/nixbot-deploy.sh` to pull repeated SSH context setup into
  `prepare_host_ssh_contexts`, so host key handling and remote-build host
  enrollment stay defined in one place.
- Added `resolve_ssh_identity_file` to centralize the repeated
  resolve-and-validate flow for deploy and bootstrap SSH keys.
- Collapsed top-level action dispatch into `run_deploy_request_action` so
  `run_requested_action` stays focused on run setup, summary handling, and exit
  status.
- Intended scope was cleanup only: no deploy ordering, bastion-trigger, or
  bootstrap semantics were changed.
