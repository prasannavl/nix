# pvl-x2 Compose Config Centralization (2026-03-10)

## Durable state

- `services.podmanCompose.<stack>.instances.<name>.exposedPorts` is the source
  of truth for compose-managed host ports and firewall intent.
- `hosts/pvl-x2/services.nix` owns those per-instance port definitions.
- Live compose stacks remain file-backed under `hosts/pvl-x2/compose/**`, while
  generated `.env` files still derive runtime values from `exposedPorts` and
  other instance metadata.
- `lib/podman.nix` opens compose-managed firewall ports from `exposedPorts`;
  `hosts/pvl-x2/firewall.nix` should only keep non-compose and host-specific
  rules.
- Secret values stay on the existing `age.secrets` plus `envSecrets` path.
