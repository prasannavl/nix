## Context

`nixos-rebuild-ng` prints some final status messages across two streams: the text
prefix goes to stderr while the result path goes to stdout. When `nixbot`
captured deploy and rollback output using parent-shell `2>&1` plus process
substitution, those writes could arrive out of order in logs.

## Decision

Add a small `run_with_combined_output` helper in `scripts/nixbot-deploy.sh`
that performs `exec 2>&1` inside the child subshell before invoking the target
command. Use it for deploy and rollback logging paths.

## Outcome

Deploy and rollback logs now receive a single ordered output stream from the
child process, which avoids split-line artifacts such as:

- `Done. The new configuration is ` appearing without the path beside it
- the matching `/nix/store/...` path appearing earlier in the log
