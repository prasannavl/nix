{registryModule}: {
  config,
  lib,
  ...
}: let
  groupedUnits = builtins.groupBy (entry: entry.name) config._ab.nixos.registeredUnits;
in {
  imports = [
    registryModule
    ./options.nix
  ];

  config.services.abird-host-agent.services =
    lib.mapAttrs (
      _: entries: {
        units =
          map
          (entry:
            builtins.removeAttrs entry ["name"])
          entries;
      }
    )
    groupedUnits;
}
