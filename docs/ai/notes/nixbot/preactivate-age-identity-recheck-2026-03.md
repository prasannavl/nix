# Preactivate Age Identity Recheck (2026-03)

## Scope

Records the deploy-side fix for Incus guest switches where the machine age
identity could be present during the initial deploy probe but missing again by
the time agenix decrypted secrets during activation.

## Decision

- `pkgs/nixbot/nixbot.sh` now performs a second
  `inject_host_age_identity_key()` call with the prepared deploy context
  immediately before invoking `nixos-rebuild-ng`.
- Immediately after that reinjection point, nixbot now waits until
  `/var/lib/nixbot/.age/identity` is visible from a `systemd-run --pipe`
  execution context, which matches the remote activation path used by
  `nixos-rebuild-ng`.
- The existing helper remains the single authority for:
  - local secret resolution
  - remote checksum validation
  - conditional reinstall when the target file is missing or mismatched

## Why

- First-switch Incus guests can transiently lose `/var/lib/nixbot/.age/identity`
  after the earlier pre-deploy injection but before agenix runs.
- Fresh Incus guests showed a sharper race: the identity could be present and
  checksum-match from the SSH session view, while agenix in the activation path
  still reported no readable identity.
- The original single injection point was too early to guarantee that
  activation-time decrypts still had a readable identity.
- A late recheck is low-risk because the helper already avoids rewriting the
  file when the target copy still matches.
- An activation-context wait is the more accurate guard because it validates
  visibility from the same transient-unit execution model that actually runs
  the switch.

## Source Of Truth Files

- `pkgs/nixbot/nixbot.sh`
