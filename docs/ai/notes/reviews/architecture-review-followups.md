# Architecture Review Followups

## Scope

Condensed record of the broad architecture reviews and the follow-up fixes that
already landed across `nixbot`, `lib/incus`, and `systemd-user-manager`.

## Durable findings

- `lib/incus` should use exact instance queries and fail-closed semantics for
  safety-sensitive paths.
- `nixbot` should preserve real command exit status through Bash control-flow
  branches, especially in readiness and Terraform paths.
- Shared repo locking must recover from stale owners instead of spinning
  forever.
- `systemd-user-manager` metadata parsing should fail loudly; malformed JSON
  must not degrade into silent noop behavior.
- Dispatcher progress should be bounded and visible without letting journal
  polling become the thing that wedges the deploy.

## Durable refactoring direction

- Keep `systemd-user-manager` narrow and generation-driven.
- Keep Podman lifecycle behavior expressed as ordinary managed units and helper
  dependencies, not as a generic action graph inside the reconciler.
- Continue collapsing repeated metadata parsing, host metadata extraction, and
  helper boilerplate where the semantics stay unchanged.

## Remaining non-urgent themes

- `lib/incus` still benefits from batching and helper dedup where it does not
  complicate failure handling.
- `nixbot` remains a large script. Further extraction is reasonable when it
  creates clearer ownership boundaries instead of just moving text around.

## Source of truth files

- `lib/incus/default.nix`
- `lib/incus/helper.sh`
- `lib/systemd-user-manager/default.nix`
- `lib/systemd-user-manager/helper.sh`
- `pkgs/tools/nixbot/nixbot.sh`

## Provenance

- This note replaces the earlier dated architecture review and review-fix notes
  for `nixbot`, `lib/incus`, and `systemd-user-manager`.
