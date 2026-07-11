# Podman Compose Stop Cleanup Rollback 2026-07

For `removalPolicy = "delete"` and `"delete-all"`, direct project-container
cleanup is a valid fallback after `podman compose down` fails or times out. If
that cleanup removes the containers, `ExecStop` has achieved the requested stop
state and should return success. Otherwise a rollback can fail even though the
compose service was actually stopped and removed.

The helper-level invariant is:

- `delete` / `delete-all`: failed compose stop plus successful direct cleanup is
  a successful `cmd_stop`.
- `stop`: failed `podman compose stop` remains a failure; direct deletion is not
  an acceptable fallback for a graceful stop policy.
