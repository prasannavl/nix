# Nixbot Known-Hosts Isolation

## Context

`nixbot` was still vulnerable to operator-machine `known_hosts` drift even
after per-host deploy SSH contexts started using temp `UserKnownHostsFile`
files. Two gaps remained:

- some SSH wrappers did not force `GlobalKnownHostsFile=/dev/null`
- managed repo `git clone` / `git fetch` still used ambient SSH defaults for
  SSH remotes

This showed up when nested guests were recreated and the operator's personal
`~/.ssh/known_hosts` no longer matched the new host keys.

## Decision

Treat `nixbot` as fully self-contained for SSH host-key trust:

- all deploy/bootstrap SSH contexts must set both:
  - `GlobalKnownHostsFile=/dev/null`
  - `UserKnownHostsFile=<nixbot temp file>`
- proxy-command wrappers must carry the same isolation
- bastion-trigger SSH must carry the same isolation
- managed repo `git clone` / `git fetch` for SSH remotes must build a
  temp scanned known-hosts file from the remote URL and pass it via
  `GIT_SSH_COMMAND`

## Implementation

- `init_known_hosts_ssh_context()` now injects `GlobalKnownHostsFile=/dev/null`
  alongside the existing per-run `UserKnownHostsFile`
- `write_proxy_command_script()` now passes `GlobalKnownHostsFile=/dev/null`
- `ensure_repo_root_exists()` and `fetch_repo_root_origin()` now detect SSH
  remotes, scan the repo host key into a temp file, and use that isolated file
  via `GIT_SSH_COMMAND`

## Operational Effect

- `nixbot` no longer consults the operator machine's SSH known-hosts files for
  deploy/bootstrap/proxy/repo-refresh SSH traffic
- host-key trust now comes only from:
  - explicit `--known-hosts` / `--bastion-known-hosts` inputs, or
  - runtime discovery (`ssh-keyscan`) into nixbot-managed temp files
