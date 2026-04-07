{
  lib,
  pkgs,
  config,
  ...
}: let
  cfg = config.services.systemdUserManager;
  collectionsLib = import ../flake/collections {lib = lib;};

  unitType = lib.types.submodule ({name, ...}: {
    options = {
      user = lib.mkOption {
        type = lib.types.str;
        description = "User account owning the systemd --user manager.";
      };

      unit = lib.mkOption {
        type = lib.types.str;
        default = "${name}.service";
        description = "User unit name to keep started by the per-user reconciler.";
      };

      stopOnRemoval = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether removing the managed entry should stop the old user unit during dispatcher stop.";
      };

      restartTriggers = lib.mkOption {
        type = lib.types.listOf lib.types.unspecified;
        default = [];
        description = "Triggers that mark this managed unit as changed.";
      };

      stampPayload = lib.mkOption {
        type = lib.types.nullOr lib.types.unspecified;
        default = null;
        description = "Optional explicit payload to hash for this managed unit stamp. Defaults to the managed-unit definition fields.";
      };
    };
  });

  instances =
    lib.mapAttrsToList
    (name: unit:
      unit
      // {
        unitName = name;
      })
    cfg.instances;

  sanitizeUserKey = user: lib.strings.sanitizeDerivationName user;

  dispatcherServiceNameForUser = user: "systemd-user-manager-dispatcher-${sanitizeUserKey user}";
  reconcilerServiceNameForUser = user: "systemd-user-manager-reconciler-${sanitizeUserKey user}";

  bootReadyTargetName = "systemd-user-manager-ready.target";
  managedUserActionPath = "/run/wrappers/bin:/run/current-system/sw/bin";
  dispatcherMetadataPointerRelDir = "systemd-user-manager/dispatchers";
  deferredRestartRequestDir = "/run/systemd-user-manager/restart-requests";

  helperPackage = pkgs.writeShellApplication {
    name = "systemd-user-manager-helper";
    excludeShellChecks = ["SC1091"];
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.jq
      pkgs.systemd
      pkgs.util-linux
    ];
    runtimeEnv = {
      SYSTEMD_USER_MANAGER_BOOT_READY_TARGET = bootReadyTargetName;
      SYSTEMD_USER_MANAGER_DISPATCHER_METADATA_POINTER_REL_DIR = dispatcherMetadataPointerRelDir;
      SYSTEMD_USER_MANAGER_DEFERRED_RESTART_REQUEST_DIR = deferredRestartRequestDir;
      SYSTEMD_USER_MANAGER_MANAGED_USER_ACTION_PATH = managedUserActionPath;
    };
    text = ''
      source ${./helper.sh}
      main "$@"
    '';
  };
  helperScript = "${helperPackage}/bin/systemd-user-manager-helper";

  userUidFor = user: let
    users = config.users.users;
  in
    if builtins.hasAttr user users && users.${user}.uid != null
    then users.${user}.uid
    else throw "services.systemdUserManager: user '${user}' is missing or has null uid in users.users";

  mkUnitEntry = managedUnit: let
    stampPayload =
      if managedUnit.stampPayload != null
      then managedUnit.stampPayload
      else {
        kind = "unit";
        unit = managedUnit.unit;
        stopOnRemoval = managedUnit.stopOnRemoval;
        restartTriggers = managedUnit.restartTriggers;
      };
    stamp = builtins.hashString "sha256" (builtins.toJSON stampPayload);
  in {
    user = managedUnit.user;
    name = managedUnit.unitName;
    unit = managedUnit.unit;
    stopOnRemoval = managedUnit.stopOnRemoval;
    stamp = stamp;
  };

  managedUnitsByUser =
    builtins.foldl'
    (acc: managedUnit: let
      current = acc.${managedUnit.user} or [];
      unitEntry = mkUnitEntry managedUnit;
    in
      acc
      // {
        ${managedUnit.user} = current ++ [unitEntry];
      })
    {}
    instances;

  managedUsers = builtins.attrNames managedUnitsByUser;

  generatedDispatcherServiceNames =
    map dispatcherServiceNameForUser managedUsers;

  generatedReconcilerServiceNames =
    map reconcilerServiceNameForUser managedUsers;

  duplicateGeneratedSystemdServiceNames =
    collectionsLib.duplicateValues (generatedDispatcherServiceNames ++ generatedReconcilerServiceNames);

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
      groups = groups;
    });

  userMetadataByUser =
    lib.mapAttrs
    (user: userUnits: let
      sortedUnits = lib.sort (a: b: a.name < b.name) userUnits;
      metadata = {
        version = 1;
        user = user;
        identityStamp = userIdentityStampFor user;
        managedUnits =
          map
          (managedUnit: {
            name = managedUnit.name;
            unit = managedUnit.unit;
            stopOnRemoval = managedUnit.stopOnRemoval;
            stamp = managedUnit.stamp;
          })
          sortedUnits;
      };
      rendered = builtins.toJSON metadata;
    in {
      json = metadata;
      hash = builtins.hashString "sha256" rendered;
      file = pkgs.writeText "systemd-user-manager-${sanitizeUserKey user}.json" rendered;
    })
    managedUnitsByUser;

  artifactValuesByName =
    lib.mapAttrs'
    (_: artifacts:
      lib.nameValuePair artifacts.name artifacts.value);

  mkUserReconciler = user: _: let
    metadata = userMetadataByUser.${user};
    serviceName = reconcilerServiceNameForUser user;
  in {
    metadataFile = metadata.file;
    metadataHash = metadata.hash;
    serviceName = serviceName;
    user = user;
    name = serviceName;
    value = {
      description = "Reconcile managed systemd --user units for ${user}";
      unitConfig.ConditionUser = user;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Environment = [
          "PATH=${managedUserActionPath}"
          "SYSTEMD_USER_MANAGER_USER=${user}"
          "SYSTEMD_USER_MANAGER_METADATA=${metadata.file}"
        ];
        TimeoutStartSec = 900;
        ExecStart = "${helperScript} reconciler-apply";
      };
    };
  };

  userReconcilersByUser = lib.mapAttrs mkUserReconciler managedUnitsByUser;

  mkDispatcherService = user: _: let
    userUid = userUidFor user;
    userAtService = "user@${toString userUid}.service";
    reconciler = userReconcilersByUser.${user};
    metadata = userMetadataByUser.${user};
    serviceName = dispatcherServiceNameForUser user;
  in {
    name = serviceName;
    metadataFile = metadata.file;
    metadataPointerEtcPath = "${dispatcherMetadataPointerRelDir}/${serviceName}.metadata";
    value = {
      description = "Dispatch managed systemd --user reconciliation for ${user}";
      after = [
        "multi-user.target"
        userAtService
      ];
      wantedBy = ["multi-user.target"];
      wants = [userAtService];
      restartTriggers = [
        metadata.hash
        reconciler.metadataHash
        helperScript
      ];
      restartIfChanged = true;
      stopIfChanged = true;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "root";
        Environment = [
          "SYSTEMD_USER_MANAGER_USER=${user}"
          "SYSTEMD_USER_MANAGER_UID=${toString userUid}"
          "SYSTEMD_USER_MANAGER_METADATA=${metadata.file}"
          "SYSTEMD_USER_MANAGER_RECONCILER_SERVICE=${reconciler.serviceName}.service"
        ];
        TimeoutStartSec = 900;
        TimeoutStopSec = 900;
        ExecStart = "${helperScript} dispatcher-start";
      };
    };
  };

  dispatcherServicesByUser = lib.mapAttrs mkDispatcherService managedUnitsByUser;

  previewManifest = pkgs.writeText "systemd-user-manager-preview-manifest.json" (
    builtins.toJSON (
      map
      (user: {
        user = user;
        metadataFile = userReconcilersByUser.${user}.metadataFile;
        reconcilerService = "${userReconcilersByUser.${user}.serviceName}.service";
      })
      managedUsers
    )
  );
in {
  options.services.systemdUserManager = {
    instances = lib.mkOption {
      type = lib.types.attrsOf unitType;
      default = {};
      description = ''
        Managed systemd --user units reconciled through one dispatcher and one
        user-side reconciler per user.
      '';
    };
  };

  config = {
    environment.etc =
      lib.mapAttrs'
      (_: artifacts:
        lib.nameValuePair artifacts.metadataPointerEtcPath {
          text = "${artifacts.metadataFile}\n";
        })
      dispatcherServicesByUser;

    system.activationScripts.systemdUserManagerStopOld = {
      supportsDryActivation = false;
      text = ''
        set -eu
        case "''${NIXOS_ACTION-}" in
          switch|test)
            old_system="$(readlink -f /run/current-system 2>/dev/null || true)"
            if [ -z "$old_system" ]; then
              old_system=/run/current-system
            fi
            SYSTEMD_USER_MANAGER_OLD_SYSTEM="$old_system" \
            SYSTEMD_USER_MANAGER_NEW_SYSTEM="$systemConfig" \
            ${lib.escapeShellArg helperScript} activation-stop-old
            ;;
        esac
      '';
    };

    system.activationScripts.systemdUserManagerDryActivatePreview = {
      deps = ["users"];
      supportsDryActivation = true;
      text = ''
        set -eu
        if [ "''${NIXOS_ACTION-}" = dry-activate ]; then
          old_system="$(readlink -f /run/current-system 2>/dev/null || true)"
          if [ -z "$old_system" ]; then
            old_system=/run/current-system
          fi
          SYSTEMD_USER_MANAGER_OLD_SYSTEM="$old_system" \
          SYSTEMD_USER_MANAGER_NEW_SYSTEM="$systemConfig" \
          SYSTEMD_USER_MANAGER_PREVIEW_MANIFEST=${lib.escapeShellArg previewManifest} \
          ${lib.escapeShellArg helperScript} activation-dry-preview
        fi
      '';
    };

    assertions =
      [
        {
          assertion = duplicateGeneratedSystemdServiceNames == [];
          message = "services.systemdUserManager: duplicate generated systemd service names: ${lib.concatStringsSep ", " duplicateGeneratedSystemdServiceNames}";
        }
      ]
      ++ lib.concatMap
      (managedUnit: [
        {
          assertion = builtins.hasAttr managedUnit.user config.users.users;
          message = "services.systemdUserManager: users.users.${managedUnit.user} is not defined";
        }
        {
          assertion = (! builtins.hasAttr managedUnit.user config.users.users) || (config.users.users.${managedUnit.user}.uid != null);
          message = "services.systemdUserManager: users.users.${managedUnit.user}.uid must be set";
        }
      ])
      instances;

    systemd = {
      services =
        artifactValuesByName dispatcherServicesByUser;

      user.services =
        artifactValuesByName userReconcilersByUser;

      user.targets.${lib.removeSuffix ".target" bootReadyTargetName} = {
        description = "Managed user units ready target";
      };
    };
  };
}
