# Nixbot If-Compound Exit Status Swallow (2026-03)

## Context

`nixbot` had several helpers that used this Bash pattern:

```bash
if cmd; then
  return 0
fi
rc="$?"
```

That is wrong. After the `if` compound finishes, `$?` is the status of the
compound itself, not the original failing command. When the condition fails and
there is no `else`, Bash reports `0` for the `if` compound, so the real failure
status is lost.

## Impact

- `retry_transport_command()` could turn non-`255` command failures into
  success, defeating fail-fast behavior.
- `retry_transport_capture()` could do the same for captured-output probes.
- `target_file_matches_expected_value()` could misreport remote-file validation
  failures as success.
- `probe_primary_deploy_target()` could print transport retries but still report
  the primary path as healthy afterward.
- Parent readiness barriers could print a failure and still return success.
- Rollback and best-effort reporting helpers could misclassify failed commands
  after the same pattern.

This explains deploy-wave continuation after readiness failures that should have
aborted the wave.

The lingering March 2026 cases that reproduced this were:

- `target_file_matches_expected_value()`
- `probe_primary_deploy_target()`
- `run_parented_host_operation_with_retry()`

## Rule

When a helper needs the exit status of a failed command tested by `if`, capture
it in the `else` branch:

```bash
if cmd; then
  return 0
else
  rc="$?"
fi
```

Do not read `$?` after the `if` compound.
