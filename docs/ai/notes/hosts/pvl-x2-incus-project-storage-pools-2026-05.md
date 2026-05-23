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
