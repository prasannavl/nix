# Nixbot Incus Guest Snapshot Wait

## Status

Historical. This guardrail was later removed after activation-time Incus guest
reconcile was changed to a best-effort default and the guest-specific waits were
dropped from `hosts/nixbot.nix`.

## Context

Incus guests such as `llmug-rivendell`, `gap3-gondor`, and `gap3-rivendell` can
be recreated during deployment of their parent host. `nixbot` records a rollback
snapshot for each target before deploy, and for dependent hosts it retries that
snapshot when their deploy wave is reached.

After a parent host recreates a guest, the guest may exist but still not be
reachable over SSH when the retry snapshot runs. A small retry delay is useful
as a safety margin for those hosts.

The original failure that led to this change included errors like:

- forced-command bootstrap check failed
- failed to allocate remote temporary file for bootstrap key
- unable to record pre-deploy generation; refusing deploy without rollback
  snapshot

## Decision

Reuse the existing per-host `wait` setting for the snapshot retry path instead
of inventing a separate snapshot-only delay. Keep the configured waits short;
this is only a guardrail, not the primary fix for host-specific SSH/bootstrap
problems.

The later diagnosis for `llmug-rivendell` was guest firewall policy: SSH from
the parent host over `incusbr0` must be allowed for `nixbot` snapshot/deploy
access. `gap3-gondor` already had this; `llmug-rivendell` and `gap3-rivendell`
were brought into line with
`networking.firewall.trustedInterfaces = [ "incusbr0" ]`.

## Implementation

- `pkgs/nixbot/nixbot.sh` now has `wait_before_host_phase`, used by both:
  - `run_deploy_job`
  - `ensure_wave_snapshots`
- `hosts/nixbot.nix` sets short waits for Incus guests:
  - `llmug-rivendell = 3`
  - `gap3-gondor = 3`
  - `gap3-rivendell = 3`

## Operational Effect

- Initial wave-0 snapshots are unchanged.
- Retry snapshots for later waves now wait before probing a newly recreated
  guest.
- The same host-level `wait` value applies consistently to both snapshot retry
  and deploy.
