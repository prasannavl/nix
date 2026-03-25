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

      observeUnit = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "User unit whose active state determines whether a changed bridge should take action. Defaults to unit.";
      };

      changeUnit = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "User unit to operate on when the bridge changes. Defaults to unit.";
      };

      onChangeAction = lib.mkOption {
        type = lib.types.enum ["restart" "reload" "start"];
        default = "restart";
        description = "User-manager action to run for previously active units when the bridge changes.";
      };

      startOnInitial = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether a brand-new bridge should start its unit on first activation.";
      };

      stopUnitOnStop = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether bridge stop should stop the managed unit.";
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

  userIdentityStampFor = user: let
    userCfg = config.users.users.${user};
    groupNames = lib.unique ([userCfg.group] ++ userCfg.extraGroups);
    groups =
      lib.genAttrs
      (builtins.filter (group: builtins.hasAttr group config.users.groups) groupNames)
      (group: config.users.groups.${group});
  in
    builtins.hashString "sha256" (builtins.toJSON {
      user = userCfg;
      inherit groups;
    });

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
    observeUnit =
      if bridge.observeUnit != null
      then bridge.observeUnit
      else bridge.unit;
    escapedObserveUnit = lib.escapeShellArg observeUnit;
    changeUnit =
      if bridge.changeUnit != null
      then bridge.changeUnit
      else bridge.unit;
    escapedChangeUnit = lib.escapeShellArg changeUnit;
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
        userctl --no-block ${bridge.onChangeAction} ${escapedChangeUnit}
        ${pkgs.coreutils}/bin/rm -f ${escapedStateFile} ${escapedStopSeenFile}
        exit 0
      fi
      if [ -f ${escapedStopSeenFile} ]; then
        ${pkgs.coreutils}/bin/rm -f ${escapedStopSeenFile}
        exit 0
      fi
      if [ "${
        if bridge.startOnInitial
        then "1"
        else "0"
      }" = 1 ]; then
        # No old-generation stop record: treat as new bridge/service and start it.
        userctl --no-block start ${escapedUnit}
      fi
    '';

    stopScript = pkgs.writeShellScript "systemd-user-manager-${bridgeName}-stop" ''
      set -eu
      ${mkMachineUserctlRetryLib escapedMachine}
      restart_worthy=0
      if active_state="$(userctl show --property=ActiveState --value ${escapedObserveUnit})"; then
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
      if [ "${
        if bridge.stopUnitOnStop
        then "1"
        else "0"
      }" = 1 ]; then
        # Always attempt stop on bridge stop so old-generation teardown is not
        # skipped by pre-check races.
        userctl stop ${escapedUnit}
      fi
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
    system.activationScripts.systemdUserManagerIdentity = lib.stringAfter ["users"] (
      let
        stateDir = "/run/nixos/systemd-user-manager";
      in
        ''
          set -eu
          ${pkgs.coreutils}/bin/install -d -m 0755 ${stateDir}
        ''
        + lib.concatStringsSep "\n"
        (lib.mapAttrsToList
          (user: _: let
            uid = toString (userUidFor user);
            stamp = userIdentityStampFor user;
            stampFile = "${stateDir}/identity-${sanitizeUserKey user}.stamp";
          in ''
            current_stamp="$(${pkgs.coreutils}/bin/cat ${lib.escapeShellArg stampFile} 2>/dev/null || true)"
            if [ "$current_stamp" != "${stamp}" ]; then
              if ${pkgs.systemd}/bin/systemctl is-active --quiet user@${uid}.service; then
                ${pkgs.systemd}/bin/systemctl restart user@${uid}.service
              fi
              ${pkgs.coreutils}/bin/printf '%s\n' "${stamp}" > ${lib.escapeShellArg stampFile}
            fi
          '')
          bridgesByUser)
    );

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
