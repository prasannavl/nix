# pvl-x2 Compose Config Centralization (2026-03-10)

- Extended `services.podmanCompose.<stack>.instances.<name>` with an
  `exposedPorts` option for named host ports and firewall intent metadata.
- Moved live `pvl-x2` compose stack ports into per-instance `exposedPorts`
  definitions inside `hosts/pvl-x2/services.nix`.
- Restored `pvl-x2` live stacks to file-backed compose YAML sources under
  `hosts/pvl-x2/compose/**`, while generating per-instance `.env` files from
  `exposedPorts` and any required runtime paths.
- Moved automatic firewall opening for compose-managed ports into
  `lib/podman.nix`, derived from `services.podmanCompose.*.instances.*.exposedPorts`.
- Reduced `hosts/pvl-x2/firewall.nix` to host-specific non-compose ports and
  interface settings.
- Left secret values on the existing `age.secrets` + `envSecrets` path.
