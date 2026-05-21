# Podman Data Dir Ownership (2026-04)

- For rootless `services.podmanCompose.*` instances, keep using staged relative
  bind mounts like `./data`, `./db-data`, or `./open-webui_data` for
  service-local state under the compose working directory.
- Do not add redundant
  `dirs.<name> = { user = 0; group = 0; scope =
  "container"; };` entries for
  those paths when the intended ownership is just container root under the
  default rootless mapping. In that mapping, container `0:0` resolves to the
  stack user on the host, which is already the default staged-dir ownership.
- Reserve `dirs` for cases that need non-default mode/ownership semantics or
  managed restrictive parent directories.
- When a service must bind-mount a host path outside the compose working
  directory, declare it as an absolute `dirs` key instead of embedding raw
  `podman unshare` shell in `serviceOverrides.preStart`.
- The parent of an absolute `dirs` path must already exist and be
  searchable/writable by the stack user; prefer the stack root as that parent.
- Absolute `dirs` entries are also ensure helpers: when a user or group is set,
  the runtime helper reapplies the requested ownership and mode even if the
  directory already exists.
- `hosts/pvl-x2/services/postgres.nix` is the canonical example of the external
  data-dir bootstrap pattern.
