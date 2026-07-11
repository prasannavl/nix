{
  lib,
  pkgs,
  ...
}: {
  options.services.migration-manager = {
    enable = lib.mkEnableOption "runtime migration gate control";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.migration-manager;
      description = "Package providing migration-manager and migration-manager-helper.";
    };

    gatePath = lib.mkOption {
      type = lib.types.str;
      default = "/run/migration-manager/gate";
      readOnly = true;
      description = "Read-only transient runtime marker path used by the migration drain.";
    };

    state = lib.mkOption {
      type = lib.types.enum ["runtime" "on" "off"];
      default = "runtime";
      description = ''
        Migration gate ownership mode. `runtime` leaves the transient live gate
        untouched during switch so migration-manager owns drain/resume for the
        current boot. `on` forces the host drained declaratively. `off` forces
        the host resumed declaratively.
      '';
    };

    managedUnits = {
      system = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            stopOnDrain = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Whether migration-manager should stop the system service when the gate is on.";
            };

            startOnResume = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Whether migration-manager should start the system service when the gate is off.";
            };

            gateStart = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Whether migration-manager should cold-start gate the system service while the drain is on.";
            };
          };
        });
        default = {};
        description = "Systemd system service units managed by the migration drain, keyed by full unit name.";
      };

      users = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            services = lib.mkOption {
              type = lib.types.attrsOf (lib.types.submodule {
                options = {
                  stopOnDrain = lib.mkOption {
                    type = lib.types.bool;
                    default = true;
                    description = "Whether migration-manager should stop the user service when the gate is on.";
                  };

                  startOnResume = lib.mkOption {
                    type = lib.types.bool;
                    default = true;
                    description = "Whether migration-manager should start the user service when the gate is off.";
                  };

                  gateStart = lib.mkOption {
                    type = lib.types.bool;
                    default = true;
                    description = "Whether migration-manager should cold-start gate the user service while the drain is on.";
                  };
                };
              });
              default = {};
              description = "Native systemd user service units managed by the migration drain, keyed by full .service unit name.";
            };

            targets = lib.mkOption {
              type = lib.types.attrsOf (lib.types.submodule {
                options = {
                  stopOnDrain = lib.mkOption {
                    type = lib.types.bool;
                    default = true;
                    description = "Whether migration-manager should stop the user target when the gate is on.";
                  };

                  startOnResume = lib.mkOption {
                    type = lib.types.bool;
                    default = true;
                    description = "Whether migration-manager should start the user target when the gate is off.";
                  };

                  gateStart = lib.mkOption {
                    type = lib.types.bool;
                    default = true;
                    description = "Whether migration-manager should cold-start gate the user target while the drain is on.";
                  };
                };
              });
              default = {};
              description = "Native systemd user targets managed by the migration drain, keyed by full .target unit name.";
            };
          };
        });
        default = {};
        description = "Native systemd user units managed by the migration drain, keyed by user name.";
      };
    };
  };
}
