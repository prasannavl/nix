# Human Host Docs Add-Host Flow (2026-04)

## Scope

Update `docs/hosts.md` so the human-facing "How To Add A New Host" section
matches the current repo workflow.

## Changes

- Added the missing Incus parent-host declaration step for nested guests.
- Documented `parent` as the standard nested-guest field in `hosts/nixbot.nix`.
- Clarified that `parent` already provides the parent readiness and ordering
  edge, so a duplicate `after = [parent]` entry is not needed.
- Added the concrete machine-secret workflow:
  - `age-keygen`
  - commit `<host>.key.pub`
  - add recipient policy in `data/secrets/default.nix`
  - `scripts/age-secrets.sh encrypt`
  - `scripts/age-secrets.sh clean`
- Clarified that new hosts can copy a similar existing host and only keep the
  modules they actually need.
