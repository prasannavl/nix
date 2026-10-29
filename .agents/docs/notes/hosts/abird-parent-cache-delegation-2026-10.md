# Abird parent-cache delegation

- Pvl Harmonia remains the signed publisher; existing Pvl clients and private
  signing-key ownership are unchanged.
- Nest has one fixed instance-bound proxy on `10.10.0.10:5000`, connecting to
  parent `127.0.0.1:5000`. No IPv6 cache listener is declared.
- Proxies are live-managed, outside recreation hashes and lifecycle unit
  triggers. Nest uses default `auto` reconciliation again. Native Incus hotplug
  converges owned devices; ambiguous legacy metadata fails closed. The first
  helper/schema upgrade can still restart lifecycle services. Coordinate
  approved rollout; do not bump `recreateTag` for port cleanup. Device
  `removalPolicy` concerns disk data, not proxy convergence. See
  `../lib/incus-live-proxies-2026-10.md`.
- Only platform CI consumes this delegation. Abird configures Nest's source-only
  admission and early guard, including same-fabric traffic. Fleet targets
  consume CI's materialized release closures, not the parent cache.
- The accepted projection uses grouped selectors for CI SSH to direct/dev/Gondor
  fabrics; exact-source TCP 5000 to Nest; and exact-source TCP 22 to the Gondor
  parent. Fabric routing stays dual-stack; Nest's service guard permits only CI
  IPv4 on `eth0` and drops other TCP-5000 traffic, including IPv6. Broad
  Nest-cache grants are removed.
- Contained-fabric access to Pvl host services stays denied. No public ingress,
  general parent management permission or extra CI forwarding port is added.
- Pvl's own origin remains in `config/pvl/nix-caches.nix`; self-exclusion avoids
  querying its own cache. Shared selector/cache helpers and tests match Abird.
- Pvl does not import the private Abird repository. Its independently evaluated
  identity test checks the complete generated admission matrix, not just counts.

Abird owns plan `2026-w44-platform-ci-cache-layers`. Coordinated deployment,
proxy cold-start, live flows, signed reuse and GC/rollback retention remain
separately authorized rollout gates. No live guest changes occur while editing.
