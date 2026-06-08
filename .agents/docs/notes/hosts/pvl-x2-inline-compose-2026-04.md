# PVL-X2 Inline Compose Migration (2026-04)

- Converted the `hosts/pvl-x2/services/*` manual `docker.compose.yaml` files
  into inline `source = '' ... '';` definitions inside each service module.
- Removed the standalone compose files after migration so the host service
  wiring stays in Nix.
- Kept auxiliary non-entry compose assets such as
  `hosts/pvl-x2/services/immich/hwaccel.ml.yml` and
  `hosts/pvl-x2/services/immich/hwaccel.transcoding.yml` because the Immich
  compose source still uses `extends` against them.
- Left `hosts/pvl-x2/services/zulip/default.nix` disabled, but preserved its
  last compose definition inline in the module as a parked reference until the
  stack is wired back into the host.
