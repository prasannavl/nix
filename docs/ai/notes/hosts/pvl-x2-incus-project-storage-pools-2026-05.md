# pvl-x2 Incus Project Storage Pools 2026-05

`pvl-x2` now declares separate Btrfs storage pools for the tenant Incus
projects:

- `pvl`
- `abird`
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

The one-shot `pvl-x2` migration was removed after live validation confirmed the
tenant projects, profiles, and known tenant volumes had moved to their final
pools. The shared `preseedMigrations` support remains available for future
schema or live-state transitions.
