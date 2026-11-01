# Incus live proxy reconciliation — 2026-10

## Contract

- Shared `lib/incus/default.nix` and `helper.sh` classify proxies separately
  from disks and recreate-only devices. Proxy specifications are absent from
  instance config/lifecycle hashes and lifecycle unit change triggers.
- The existing `incus-machines-limits` unit also converges proxies; its live
  trigger includes their specifications. Full instance reconciliation uses the
  same helper. No new scheduler, proxy server or device DSL.
- Incus 7.5.1 supports proxy hotplug. Use native add/set/remove; batch property
  changes and optional-key clearing into one set operation. A proxy update may
  interrupt its connections, but does not itself stop/start/recreate the guest.
- Preserve the v1 proxy-inclusive wire hash in `user.nixos-meta`. Store the
  proxy-free applied hash, original legacy hash, controller and owned names in
  versioned `user.nixos-proxy-meta`. Old helpers retain their original hash and
  leave this sidecar intact when rewriting v1 metadata.
- Validate sidecar version, shape, controller and legacy-hash binding before
  lifecycle/adoption actions. Reject unowned local name collisions,
  inherited-device additions and type conflicts. Preserve unrelated devices.
- GC updates removal/suspend policy only; it must not acknowledge unapplied
  hashes, lifecycle tags or device ownership. Takeover releases both keys.
- Reserve ownership before device changes, prune obsolete owned names only after
  success, and retain retryable reservations on partial failure. Remove obsolete
  listeners before adding replacements so same-port renames work. Multiple
  device changes are not atomic: a failed replacement can leave its listener
  unavailable until retry. Failure never authorizes guest recreation.
- Live-only reconciliation skips missing/ignored guests and does not start
  stopped guests. Fresh guests receive proxies before their first start.
  Existing immutable-drift and explicit lifecycle-tag semantics remain intact.

## Legacy transition

Old metadata hashes included proxy definitions. Removing that input without a
migration would itself look like immutable drift.

- Accept an unchanged proxy-free hash, an exact legacy declaration hash, or a
  reconstructed legacy hash using the desired immutable payload and observed
  local proxies. Only proven previously managed proxies are adopted.
- Ambiguous proxy migration fails closed. Restore the unchanged immutable
  declaration and migrate first; do not bump `recreateTag` merely to clean up a
  port. An explicitly authorized recreation remains a separate lifecycle action.
- Existing declarative immutable drift remains visible; proxy metadata updates
  do not silently acknowledge it.
- The unsafe intermediate preview wrote `proxyDevices` and a proxy-free hash
  directly into v1 metadata. Refuse that format, malformed sidecars and orphaned
  ownership before mutation; do not guess a rollback hash or use adoption to
  bypass the refusal.
- The initial helper/schema/policy upgrade can still change existing lifecycle
  services and cause a stop/start. Stable unit/hash tests prove subsequent
  proxy-only edits do not trigger that path, **not a zero-downtime first
  upgrade**.

## Local verification and rollout boundary

- Shared module tests compare lifecycle hashes/unit definitions and live
  triggers.
- Stateful fake-Incus regressions cover add/update/clear/rename/remove,
  idempotency, ownership/profile/type conflicts, failures and retries, metadata
  write failures, ETag retry, legacy migration/refusal and guest lifecycle
  states.
- A Nix-generated payload/hash is migrated by the Bash helper, including
  Unicode, quotes and newlines; this checks the actual cross-language
  serialization seam.
- All changed Incus implementation/test files remain byte-identical across Abird
  and Pvl. Nest can return to the default `auto` policy; its IPv4 cache listener
  and CI-only firewall policy remain unchanged.
- These are local module/helper tests, not live Incus hotplug, private-address
  cold-start or cache reachability proof. Coordinate and authorize rollout
  separately; inspect errors rather than using recreation as a fallback.

## Original preview checkpoint — unsafe

The initial implementation wrote a proxy-free `configHash` with the legacy
metadata version. An old helper accepted it, compared it with a proxy-inclusive
hash and could auto-recreate the guest during rollback. Nest's existing
`incus-api` proxy was sufficient to trigger the risk. Do not deploy or use that
intermediate preview as a rollback target.

The separate wire/sidecar contract fixes this proxy-only transition hazard; see
`incus-proxy-rollback-2026-10.md` for historical-helper tests and evidence. Old
helpers preserve guests but cannot undo newer live proxy edits. Restore old
listeners with the fixed helper before an old-generation rollback when network
configuration must also revert. Ordinary immutable drift and explicit
`recreateTag` intent retain their lifecycle semantics. No live rollback has been
attempted; retain health checks and automatic rollback.
