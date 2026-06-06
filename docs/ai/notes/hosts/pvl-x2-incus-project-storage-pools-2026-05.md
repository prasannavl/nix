# pvl-x2 Incus Project Storage Pools 2026-05

`pvl-x2` now declares separate Btrfs storage pools for the tenant Incus
projects:

- `pvl`
- `abird`
- `abird-stage`
- `abird-dev`

The default Incus project keeps using the `default` pool. Each tenant project
default profile points its root disk at the matching tenant pool, and
`restricted.storage-pools.access` is limited to that same pool.

Tenant bridge networks, storage pools, default profiles, restricted project
config, and trusted firewall interfaces are generated from the host-local
`projects = { ...; }` map. Each project entry owns its `pool`, `network`, and
extra restriction `config`, keeping the preseed sections derived from one source
of truth instead of parallel maps.

Cross-project traffic policy is also parent-owned from that same map. `pvl-x2`
uses the shared `lib/incus/lib.nix` helper to render a host nftables `forward`
plus matching host `input` / `output` hooks for managed-fabric access control,
instead of relying on guest firewalls or Incus restricted project flags for
east-west isolation. The policy lives under `projects.<name>.network.policy`:

- `forwardTo = true | false | [ ... ]`: which managed fabrics this fabric may
  initiate traffic toward.
- `allowFromHost = true | false`: whether the parent host may initiate traffic
  to this fabric.
- `allowToHost = true | false`: whether this fabric may initiate traffic to the
  parent host.
- `allowToUplink = true | false`: whether this fabric may initiate traffic to
  non-managed uplink networks.
- `allowFromUplink = true | false`: whether non-managed uplink networks may
  initiate traffic to this fabric.

The helper also exports reusable policy profiles through
`incusLib.fabricPolicyProfiles`:

- `open`: permissive baseline matching the earlier no-project-policy shape
- `isolated`: no managed-fabric forwarding, no host access, uplink egress on
- `isolatedPublic`: `isolated` plus uplink-originated ingress allowed
- `contained`: `isolated` plus host-originated ingress allowed
- `containedPublic`: `contained` plus uplink-originated ingress allowed
- `quarantine`: no managed-fabric forwarding, no host access, no uplink egress

The default project fabric is configured separately from the tenant `projects`
map, but uses the same policy semantics. Host-originated traffic from `pvl-x2`
and routed traffic between the managed Incus fabrics are both gated by this
policy helper.

Volume-backed `state` disks use the tenant pool too. When a disk device omits
`pool`, `lib/incus` derives the pool from the resolved instance project. For
remote-managed instances, that means the configured remote project; for local
instances without an explicit project, that remains `default`.

The previous one-shot `pvl-x2` storage migration was removed after live
validation confirmed the tenant projects, profiles, and known tenant volumes had
moved to their final pools. The shared `preseedMigrations` support is still the
right place for explicit Incus fabric transitions.

The `abird-dev` to `abird-stage` split used that migration layer because the old
live `abird-dev` project owned the `10.10.200.0/24` bridge and the current Abird
guest volumes. Incus cannot rename non-empty projects, and networks cannot be
renamed while profiles or instances use them, so the one-shot migration created
`iabirdbr1` for stage and `iabirdbr2` for the fresh dev project, created and
prepared `abird-stage`, temporarily allowed both the old and new pools, stopped
the known guests, moved their custom and root volumes across to `abird-stage`,
retargeted stage guests off the stale `iabirddevbr0` bridge before profile
alignment could validate those stale instance devices, temporarily let
`abird-dev` reference both old and new bridges while its default profile moved,
aligned the final stage project/profile/instance network config, and started the
moved stage guests.

After live validation showed `abird-stage` on `iabirdbr1` and the fresh
`abird-dev` on `iabirdbr2`, the host-specific migration payload was removed from
`hosts/pvl-x2/incus.nix`. The generic `preseedMigrations` machinery remains in
`lib/incus` for future explicit Incus fabric transitions.
