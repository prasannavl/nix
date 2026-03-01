{
  lib,
  pkgs,
  config,
  ...
}: let
  cfg = config.services.systemdUserManager;

  unitType = lib.types.submodule ({
    name,
    config,
    ...
  }: {
    options = {
      user = lib.mkOption {
        type = lib.types.str;
        description = "User account owning the systemd --user manager.";
      };

      unit = lib.mkOption {
        type = lib.types.str;
        default = "${name}.service";
        description = "User unit name to manage (include suffix).";
      };

      restartTriggers = lib.mkOption {
        type = lib.types.listOf lib.types.unspecified;
        default = [];
        description = "Triggers that force restart of this bridge service on switch.";
      };

      serviceName = lib.mkOption {
        type = lib.types.str;
        default = "systemd-user-manager-${name}";
        description = "System service name for this bridge.";
      };
    };
  });

  mkBridgeService = bridgeName: bridge: let
    escapedUser = lib.escapeShellArg bridge.user;
    escapedUnit = lib.escapeShellArg bridge.unit;
    stateFile = "/run/nixos/systemd-user-manager/${bridge.serviceName}.was-active";
    escapedStateFile = lib.escapeShellArg stateFile;
    machine = "${bridge.user}@";
    escapedMachine = lib.escapeShellArg machine;

    startScript = pkgs.writeShellScript "systemd-user-manager-${bridgeName}-start" ''
      set -eu
      if [ ! -f ${escapedStateFile} ]; then
        exit 0
      fi
      ${pkgs.coreutils}/bin/rm -f ${escapedStateFile}
      ${pkgs.systemd}/bin/systemctl --user --machine=${escapedMachine} start ${escapedUnit} || true
    '';

    stopScript = pkgs.writeShellScript "systemd-user-manager-${bridgeName}-stop" ''
      set -eu
      ${pkgs.coreutils}/bin/install -d -m 0755 /run/nixos/systemd-user-manager
      if ${pkgs.systemd}/bin/systemctl --user --machine=${escapedMachine} --quiet is-active ${escapedUnit}; then
        ${pkgs.coreutils}/bin/touch ${escapedStateFile}
        ${pkgs.systemd}/bin/systemctl --user --machine=${escapedMachine} stop ${escapedUnit} || true
      else
        ${pkgs.coreutils}/bin/rm -f ${escapedStateFile}
      fi
    '';
  in {
    name = bridge.serviceName;
    value = {
      description = "Bridge switch behavior for ${bridge.user} user unit ${bridge.unit}";
      wantedBy = ["multi-user.target"];
      restartTriggers = bridge.restartTriggers;
      restartIfChanged = true;
      stopIfChanged = true;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "root";
        ExecStart = "${startScript}";
        ExecStop = "${stopScript}";
      };
    };
  };
in {
  options.services.systemdUserManager.bridges = lib.mkOption {
    type = lib.types.attrsOf unitType;
    default = {};
    description = ''
      System-managed bridge units that apply old-stop/new-start switching semantics
      to selected systemd --user units via systemctl --user --machine=<user>@.
    '';
  };

  config = {
    systemd.services = lib.listToAttrs (lib.mapAttrsToList mkBridgeService cfg.bridges);
  };
}
