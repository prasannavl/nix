{
  config,
  lib,
  ...
}: let
  registeredPorts = config._ab.nixos.registeredPorts;
  portGroups = builtins.groupBy (entry: toString entry.port) registeredPorts;
  conflicts = lib.filterAttrs (_: entries: builtins.length entries > 1) portGroups;
  conflictMessages =
    lib.mapAttrsToList (
      port: entries:
        "Port ${port} is used by multiple enabled services: "
        + lib.concatMapStringsSep ", " (entry: entry.name) entries
        + ". Assign distinct ports to avoid bind conflicts."
    )
    conflicts;
  unitType = lib.types.submodule {
    options = {
      name = lib.mkOption {
        type = lib.types.str;
        description = "Logical portable service name.";
      };
      scope = lib.mkOption {
        type = lib.types.enum ["system" "user"];
        description = "Systemd manager scope.";
      };
      user = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "User-manager owner when scope is user.";
      };
      unit = lib.mkOption {
        type = lib.types.str;
        description = "Full generated systemd unit name.";
      };
    };
  };
in {
  options._ab.nixos = {
    registeredPorts = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [];
      internal = true;
      description = "Portable TCP-port claims emitted by ab.nixos service modules.";
    };

    registeredUnits = lib.mkOption {
      type = lib.types.listOf unitType;
      default = [];
      internal = true;
      description = "Portable generated systemd units emitted by ab.nixos service modules.";
    };
  };

  config.assertions =
    map (message: {
      assertion = false;
      inherit message;
    })
    conflictMessages;
}
