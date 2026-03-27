# Remote File Install Transport Retries

## Context

Fresh Incus guest deploys were still failing after snapshot readiness had
already succeeded.

Observed failure pattern:

- snapshot eventually succeeded after the parented snapshot readiness loop
- deploy then failed during host age identity installation with transport errors
  such as `Connection reset by 100.100.1.1 port 22`
- `install_local_file_via_target` treated those transport resets as hard
  failures when allocating the remote temp file, copying the file, or running
  the remote install command

## Decision

Make `install_local_file_via_target` transport-retry-aware for its three remote
transport steps:

- remote temp file allocation
- copy to the remote temp file
- remote install command execution

This keeps the retry scoped to the actual failing operation instead of adding a
second broad deploy-stage sleep or readiness barrier.

## Operational Effect

- transient SSH resets during remote file installation no longer fail deploy
  immediately
- host age identity injection can survive the same kind of short-lived transport
  instability already seen during parented guest snapshot capture
