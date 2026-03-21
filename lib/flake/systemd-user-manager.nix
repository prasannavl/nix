{
  lib,
  pkgs,
  config,
  ...
}: let
  cfg = config.services.systemdUserManager;
  bridges = lib.attrValues cfg.bridges;

  unitType = lib.types.submodule ({name, ...}: {
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

  sanitizeUserKey = user: let
    readable = lib.strings.sanitizeDerivationName user;
    digest = builtins.substring 0 8 (builtins.hashString "sha256" user);
  in "${readable}-${digest}";

  reloadServiceNameForUser = user: "systemd-user-manager-reload-${sanitizeUserKey user}";
  userUidFor = user: let
    inherit (config.users) users;
  in
    if builtins.hasAttr user users && users.${user}.uid != null
    then users.${user}.uid
    else throw "services.systemdUserManager.bridges: user '${user}' is missing or has null uid in users.users";

  bridgesByUser =
    builtins.foldl'
    (acc: bridge: let
      key = bridge.user;
      current = acc.${key} or [];
    in
      acc
      // {
        ${key} = current ++ [bridge];
      })
    {}
    bridges;

  mkMachineUserctlRetryLib = escapedMachine: ''
    is_transient_userctl_error() {
      printf '%s' "$1" | ${pkgs.gnugrep}/bin/grep -Eq \
        'Transport endpoint is not connected|Failed to connect to bus|Connection refused|No such file or directory'
    }
    userctl() {
      local out rc i
      i=0
      while [ "$i" -lt 15 ]; do
        out="$(${pkgs.systemd}/bin/systemctl --user --machine=${escapedMachine} "$@" 2>&1)" && {
          [ -n "$out" ] && printf '%s\n' "$out" >&2
          return 0
        }
        rc=$?
        if is_transient_userctl_error "$out"; then
          i=$((i + 1))
          ${pkgs.coreutils}/bin/sleep 0.2
          continue
        fi
        [ -n "$out" ] && printf '%s\n' "$out" >&2
        return $rc
      done
      [ -n "$out" ] && printf '%s\n' "$out" >&2
      return $rc
    }
  '';

  mkReloadService = user: userBridges: let
    machine = "${user}@";
    escapedMachine = lib.escapeShellArg machine;
    serviceName = reloadServiceNameForUser user;
    userUid = userUidFor user;
    userAtService = "user@${toString userUid}.service";
    userManagerStatePath = "/run/systemd/users/${toString userUid}";
    restartTriggers = lib.concatMap (bridge: bridge.restartTriggers) userBridges;
    reloadScript = pkgs.writeShellScript "systemd-user-manager-${serviceName}-reload" ''
      set -eu
      ${mkMachineUserctlRetryLib escapedMachine}
      userctl daemon-reload
    '';
  in {
    name = serviceName;
    value = {
      description = "Reload systemd --user manager for ${user}";
      after = [userAtService];
      wantedBy = [
        "multi-user.target"
        userAtService
      ];
      inherit restartTriggers;
      restartIfChanged = true;
      stopIfChanged = true;
      unitConfig.ConditionPathExists = userManagerStatePath;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "root";
        ExecStart = "${reloadScript}";
      };
    };
  };

  mkBridgeService = bridgeName: bridge: let
    escapedUnit = lib.escapeShellArg bridge.unit;
    stateFile = "/run/nixos/systemd-user-manager/${bridge.serviceName}.was-active";
    escapedStateFile = lib.escapeShellArg stateFile;
    stopSeenFile = "/run/nixos/systemd-user-manager/${bridge.serviceName}.stop-seen";
    escapedStopSeenFile = lib.escapeShellArg stopSeenFile;
    machine = "${bridge.user}@";
    escapedMachine = lib.escapeShellArg machine;
    reloadServiceName = reloadServiceNameForUser bridge.user;
    userUid = userUidFor bridge.user;
    userAtService = "user@${toString userUid}.service";
    userManagerStatePath = "/run/systemd/users/${toString userUid}";

    startScript = pkgs.writeShellScript "systemd-user-manager-${bridgeName}-start" ''
      set -eu
      ${mkMachineUserctlRetryLib escapedMachine}
      if [ -f ${escapedStateFile} ]; then
        # Replay prior-active state as restart intent.
        userctl --no-block restart ${escapedUnit}
        ${pkgs.coreutils}/bin/rm -f ${escapedStateFile} ${escapedStopSeenFile}
        exit 0
      fi
      if [ -f ${escapedStopSeenFile} ]; then
        ${pkgs.coreutils}/bin/rm -f ${escapedStopSeenFile}
        exit 0
      fi
      # No old-generation stop record: treat as new bridge/service and start it.
      userctl --no-block start ${escapedUnit}
    '';

    stopScript = pkgs.writeShellScript "systemd-user-manager-${bridgeName}-stop" ''
      set -eu
      ${mkMachineUserctlRetryLib escapedMachine}
      restart_worthy=0
      if active_state="$(userctl show --property=ActiveState --value ${escapedUnit})"; then
        case "$active_state" in
          inactive)
            restart_worthy=0
            ;;
          active|reloading|activating|deactivating|failed)
            restart_worthy=1
            ;;
          *)
            # Unknown states are treated conservatively to preserve restart intent.
            restart_worthy=1
            ;;
        esac
      else
        # Query failures are treated conservatively to preserve restart intent.
        restart_worthy=1
      fi
      ${pkgs.coreutils}/bin/install -d -m 0755 /run/nixos/systemd-user-manager
      ${pkgs.coreutils}/bin/touch ${escapedStopSeenFile}
      if [ "$restart_worthy" -eq 1 ]; then
        ${pkgs.coreutils}/bin/touch ${escapedStateFile}
      else
        ${pkgs.coreutils}/bin/rm -f ${escapedStateFile}
      fi
      # Always attempt stop on bridge stop so old-generation teardown is not
      # skipped by pre-check races.
      userctl stop ${escapedUnit}
    '';
  in {
    name = bridge.serviceName;
    value = {
      description = "Bridge switch behavior for ${bridge.user} user unit ${bridge.unit}";
      after = [
        "${reloadServiceName}.service"
        userAtService
      ];
      requires = ["${reloadServiceName}.service"];
      wantedBy = [
        "multi-user.target"
        userAtService
      ];
      inherit (bridge) restartTriggers;
      restartIfChanged = true;
      stopIfChanged = true;
      unitConfig.ConditionPathExists = userManagerStatePath;
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
    assertions =
      lib.concatMap (
        bridge: [
          {
            assertion = builtins.hasAttr bridge.user config.users.users;
            message = "services.systemdUserManager.bridges.${bridge.serviceName}: users.users.${bridge.user} is not defined";
          }
          {
            assertion = (! builtins.hasAttr bridge.user config.users.users) || (config.users.users.${bridge.user}.uid != null);
            message = "services.systemdUserManager.bridges.${bridge.serviceName}: users.users.${bridge.user}.uid must be set";
          }
        ]
      )
      bridges;

    systemd.services =
      lib.listToAttrs
      (
        (lib.mapAttrsToList mkReloadService bridgesByUser)
        ++ (lib.mapAttrsToList mkBridgeService cfg.bridges)
      );
  };
}
