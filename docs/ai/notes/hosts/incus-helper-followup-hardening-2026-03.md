# Incus Helper Follow-up Hardening

**Date**: 2026-03-30

## Summary

Follow-up cleanup after the Incus module helper split:

- deduplicate shared Incus lifecycle dependencies
- replace sourced shell command files with JSON-driven config application
- rename the misleading `escaped_name` local to `instance_name`
- switch helper loops from pipe-fed `while` forms to process substitution for
  clearer control flow
- fail closed on unsafe `delete-all` GC source-dir removals

## Key Decisions

- Keep config/meta writes structured as JSON so key/value handling stays shell
  safe without relying on generated sourced scripts.
- Treat dangerous cleanup paths conservatively. Refuse to remove `/`, `/dev`,
  `/nix`, `/var`, `/var/lib`, and non-absolute paths even when stale metadata
  requests it.

## Operational Effect

- Incus helper behavior is clearer to review and less dependent on shell quoting
  details.
- `delete-all` cleanup now errs on the side of safety for obviously dangerous
  host paths.
