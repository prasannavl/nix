# srv flakes export nixos modules

- Date: 2026-04-08
- Scope: `pkgs/srv/*/flake.nix`

## Decision

Export a native `nixosModules` module from each `pkgs/srv/*` child flake:

- `srv-ingest`
- `srv-llm`
- `srv-trading-api`
- `srv-trading-processor`
- `srv-trading-transformer-excel`

Each module follows the repo's canonical package-owned service pattern:

- `options.services.<name>.enable = lib.mkEnableOption ...`
- `options.services.<name>.package` defaults to
  `self.packages.${pkgs.system}.default`
- `config = lib.mkIf cfg.enable { systemd.services.<name> = ...; }`
- HTTP services also expose native listener options on the module and wire them
  into the unit environment instead of hardcoding ports in host files:
  - `services.srv-ingest.listenAddress`
  - `services.srv-ingest.port`
  - `services.srv-trading-api.listenAddress`
  - `services.srv-trading-api.port`

## Rationale

- These services live as package-owned child flakes under `pkgs/srv/`, so the
  service module should travel with the package.
- Hosts should be able to import `inputs.<flake>.nixosModules.default` and then
  enable the service with the native NixOS shape:
  `services.<name>.enable = true`.
- Keep the runtime surface minimal for now: package selection plus a native
  `systemd.service` definition with `Restart = "on-failure"`.
- Listener configuration belongs in the module because the binaries already read
  bind-address environment variables; the unit should own those values.

## Follow-up

- Host modules can now import the service flakes directly and enable them with
  native `services.<name>` options.
- Add service-specific runtime options later only when the binaries actually
  consume them.
