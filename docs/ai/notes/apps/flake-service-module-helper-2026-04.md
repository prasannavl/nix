# flake service module helper

- Date: 2026-04-08
- Scope: `lib/flake/service-module.nix`, `pkgs/srv/*/flake.nix`

## Decision

Move the repeated package-owned NixOS service-module boilerplate into
`lib/flake/service-module.nix`.

The helper now provides:

- `mkServiceModules`
- `mkTcpServiceModules`

## Shape

`mkServiceModules` owns the repeated native module pattern:

- `options.services.<name>.enable`
- `options.services.<name>.package`
- `config = lib.mkIf cfg.enable { systemd.services.<name> = ...; }`
- standard `ExecStart = lib.getExe cfg.package`
- standard `Restart = "on-failure"`
- standard `wantedBy = [ "multi-user.target" ]`
- standard `after = [ "network.target" ]`

`mkTcpServiceModules` extends that with:

- `services.<name>.listenAddress`
- `services.<name>.port`
- a unit environment variable that binds the binary to
  `"${cfg.listenAddress}:${toString cfg.port}"`

## Why

- The five `pkgs/srv/*` child flakes repeated nearly identical NixOS module
  definitions.
- The package-local flake should still own the service export, but the shared
  module skeleton belongs in `lib/flake`.
- TCP-listener services need one consistent way to expose listener options
  through the module instead of hardcoding them in the binary or in host glue.

## Consequences

- Child flakes stay short and declare only service-specific facts such as the
  service name and bind-address environment variable.
- Future package-owned services can reuse the same helper instead of cloning the
  whole `nixosModules` block again.
