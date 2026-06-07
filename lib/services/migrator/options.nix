{
  lib,
  pkgs,
  ...
}: {
  options.services.migrator = {
    enable = lib.mkEnableOption "runtime migration gate control";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.migrator;
      description = "Package providing migratorctl and migrator-helper.";
    };

    gatePath = lib.mkOption {
      type = lib.types.str;
      default = "/run/migrator/gate";
      readOnly = true;
      description = "Read-only transient runtime marker path used by the migration drain.";
    };

    state = lib.mkOption {
      type = lib.types.enum ["runtime" "on" "off"];
      default = "runtime";
      description = ''
        Migration gate ownership mode. `runtime` leaves the transient live gate
        untouched during switch so migratorctl owns drain/resume for the current
        boot. `on` forces the host drained declaratively. `off` forces the host
        resumed declaratively.
      '';
    };

    managedUnits = {
      system = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            stopOnDrain = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Whether migrator should stop the system service when the gate is on.";
            };

            startOnResume = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Whether migrator should start the system service when the gate is off.";
            };

            gateStart = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Whether migrator should cold-start gate the system service while the drain is on.";
            };
          };
        });
        default = {};
        description = "Systemd system service units managed by the migration drain, keyed by full unit name.";
      };

      dispatchers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Systemd system dispatcher service units restarted after migration drain state changes.";
      };
    };
  };
}
