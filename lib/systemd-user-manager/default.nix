{
  lib,
  pkgs,
  config,
  ...
}: let
  cfg = config.services.systemdUserManager;
  migratorEnabled = config.services.migrator.enable or false;
  migratorGatePath = config.services.migrator.gatePath;
  flakeUtils = import ../flake/utils.nix {lib = lib;};
  metadataVersion = 5;

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

      removalPolicy = lib.mkOption {
        type = lib.types.enum ["keep" "stop"];
        default = "stop";
        description = ''
          What to do when the managed entry is removed. `stop` stops the old
          user unit or runs `removalCommand` when set. `keep` leaves the old
          workload alone for manual takeover.
        '';
      };

      removalCommand = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf lib.types.str);
        default = null;
        description = ''
          Optional command to run as the managed user instead of a generic
          systemctl stop when this entry is removed and `removalPolicy = "stop"`.
        '';
      };

      verifyCommand = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf lib.types.str);
        default = null;
        description = ''
          Optional command to run as the managed user after the unit reaches a
          stable active state. Failure keeps reconciliation from being marked
          applied. Verification is metadata for the reconcile transaction; it
          does not by itself force a managed unit restart.
        '';
      };

      restartTriggers = lib.mkOption {
        type = lib.types.listOf lib.types.unspecified;
        default = [];
        description = "Triggers that mark this managed unit as changed.";
      };

      reloadTriggers = lib.mkOption {
        type = lib.types.listOf lib.types.unspecified;
        default = [];
        description = "Triggers that reload this managed unit when only reload-safe inputs changed. Restart triggers take precedence.";
      };

      autoStart = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether the reconciler should automatically start this managed unit when it is inactive or failed.";
      };

      state = lib.mkOption {
        type = lib.types.enum ["running" "stopped"];
        default = "running";
        description = "Desired runtime state for this managed user unit.";
      };

      timeoutStableSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 120;
        description = "Seconds to wait for this managed unit to leave activating, deactivating, or reloading states during reconciliation.";
      };

      stampPayload = lib.mkOption {
        type = lib.types.nullOr lib.types.unspecified;
        default = null;
        description = "Optional explicit payload to hash for this managed unit stamp. Defaults to the managed-unit definition fields.";
      };

      transitionNeutralStamp = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional provider-owned stamp used to distinguish policy-only changes from real managed unit drift.";
      };

      stopOnTransitionFrom = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional provider-owned token exported by the old unit state. When it matches the new unit's stopOnTransitionTo token and transitionNeutralStamp is unchanged, the unit is stopped once.";
      };

      stopOnTransitionTo = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional provider-owned token imported by the new unit state. When it matches the old unit's stopOnTransitionFrom token and transitionNeutralStamp is unchanged, the unit is stopped once.";
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
  appliedMetadataDir = "/run/systemd-user-manager/applied-metadata";
  deferredRestartRequestDir = "/run/systemd-user-manager/restart-requests";
  deferredUnitRestartRequestDir = "/run/systemd-user-manager/unit-restart-requests";
  deferredUnitReloadRequestDir = "/run/systemd-user-manager/unit-reload-requests";

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
      SYSTEMD_USER_MANAGER_APPLIED_METADATA_DIR = appliedMetadataDir;
      SYSTEMD_USER_MANAGER_DISPATCHER_METADATA_POINTER_REL_DIR = dispatcherMetadataPointerRelDir;
      SYSTEMD_USER_MANAGER_DEFERRED_RESTART_REQUEST_DIR = deferredRestartRequestDir;
      SYSTEMD_USER_MANAGER_DEFERRED_UNIT_RESTART_REQUEST_DIR = deferredUnitRestartRequestDir;
      SYSTEMD_USER_MANAGER_DEFERRED_UNIT_RELOAD_REQUEST_DIR = deferredUnitReloadRequestDir;
      SYSTEMD_USER_MANAGER_MANAGED_USER_ACTION_PATH = managedUserActionPath;
      SYSTEMD_USER_MANAGER_MIGRATOR_GATE_PATH =
        if migratorEnabled
        then migratorGatePath
        else "";
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
    declaredStampPayload =
      if managedUnit.stampPayload != null
      then {
        payload = managedUnit.stampPayload;
        autoStart = managedUnit.autoStart;
        state = managedUnit.state;
      }
      else {
        kind = "unit";
        unit = managedUnit.unit;
        removalPolicy = managedUnit.removalPolicy;
        removalCommand = managedUnit.removalCommand;
        autoStart = managedUnit.autoStart;
        state = managedUnit.state;
        restartTriggers = managedUnit.restartTriggers;
      };
    stamp = builtins.hashString "sha256" (builtins.toJSON declaredStampPayload);
    reloadStamp =
      if managedUnit.reloadTriggers == []
      then ""
      else builtins.hashString "sha256" (builtins.toJSON managedUnit.reloadTriggers);
  in {
    user = managedUnit.user;
    name = managedUnit.unitName;
    unit = managedUnit.unit;
    removalPolicy = managedUnit.removalPolicy;
    removalCommand = managedUnit.removalCommand;
    verifyCommand = managedUnit.verifyCommand;
    autoStart = managedUnit.autoStart;
    state = managedUnit.state;
    timeoutStableSeconds = managedUnit.timeoutStableSeconds;
    stamp = stamp;
    reloadStamp = reloadStamp;
    transitionNeutralStamp = managedUnit.transitionNeutralStamp;
    stopOnTransitionFrom = managedUnit.stopOnTransitionFrom;
    stopOnTransitionTo = managedUnit.stopOnTransitionTo;
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
    flakeUtils.duplicateValues (generatedDispatcherServiceNames ++ generatedReconcilerServiceNames);

  duplicateManagedUnitsByUser =
    lib.mapAttrs
    (_: userUnits:
      flakeUtils.duplicateValues (map (userUnit: userUnit.unit) userUnits))
    managedUnitsByUser;

  usersWithDuplicateManagedUnits =
    lib.filter
    (user: duplicateManagedUnitsByUser.${user} != [])
    managedUsers;

  duplicateManagedUnitMessages =
    map
    (user: "${user}: ${lib.concatStringsSep ", " duplicateManagedUnitsByUser.${user}}")
    usersWithDuplicateManagedUnits;

  userIdentityStampFor = user: let
    userCfg = config.users.users.${user};
    groupNames = lib.sort (a: b: a < b) (lib.unique ([userCfg.group] ++ userCfg.extraGroups));
    groups =
      lib.genAttrs
      groupNames
      (group:
        if builtins.hasAttr group config.users.groups
        then {gid = config.users.groups.${group}.gid;}
        else {gid = null;});
  in
    # Only restart the lingering user manager when the user's effective
    # credentials change. Hashing full user/group option attrsets causes false
    # positives when unrelated group metadata or other members change.
    builtins.hashString "sha256" (builtins.toJSON {
      user = {
        uid = userCfg.uid;
        group = userCfg.group;
        extraGroups = lib.sort (a: b: a < b) userCfg.extraGroups;
      };
      groups = groups;
    });

  userMetadataByUser =
    lib.mapAttrs
    (user: userUnits: let
      sortedUnits = lib.sort (a: b: a.name < b.name) userUnits;
      metadata = {
        version = metadataVersion;
        user = user;
        identityStamp = userIdentityStampFor user;
        managedUnits =
          map
          (managedUnit: {
            name = managedUnit.name;
            unit = managedUnit.unit;
            removalPolicy = managedUnit.removalPolicy;
            removalCommand = managedUnit.removalCommand;
            verifyCommand = managedUnit.verifyCommand;
            autoStart = managedUnit.autoStart;
            state = managedUnit.state;
            timeoutStableSeconds = managedUnit.timeoutStableSeconds;
            stamp = managedUnit.stamp;
            reloadStamp = managedUnit.reloadStamp;
            transitionNeutralStamp = managedUnit.transitionNeutralStamp;
            stopOnTransitionFrom = managedUnit.stopOnTransitionFrom;
            stopOnTransitionTo = managedUnit.stopOnTransitionTo;
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
        userAtService
      ];
      wantedBy = ["multi-user.target"];
      wants = [userAtService];
      restartTriggers = lib.unique [
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

  homeManagerOrderingByUser = lib.listToAttrs (
    lib.concatMap
    (user: let
      homeManagerUnit = "home-manager-${user}";
      dispatcherUnit = "${dispatcherServiceNameForUser user}.service";
    in
      lib.optional ((config ? home-manager) && builtins.hasAttr user config.home-manager.users) {
        name = homeManagerUnit;
        value = {
          after = [dispatcherUnit];
          wants = [dispatcherUnit];
        };
      })
    managedUsers
  );

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
  imports = [
    ../services/migrator/options.nix
  ];

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
    environment.systemPackages = [
      helperPackage
    ];

    environment.etc =
      lib.mapAttrs'
      (_: artifacts:
        lib.nameValuePair artifacts.metadataPointerEtcPath {
          text = "${artifacts.metadataFile}\n";
        })
      dispatcherServicesByUser;

    system.activationScripts.systemdUserManagerStopApplied = {
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
            ${lib.escapeShellArg helperScript} activation-stop-applied
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
        {
          assertion = usersWithDuplicateManagedUnits == [];
          message = "services.systemdUserManager: duplicate managed user units are not allowed: ${lib.concatStringsSep "; " duplicateManagedUnitMessages}";
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
        artifactValuesByName dispatcherServicesByUser
        // homeManagerOrderingByUser;

      user.services =
        artifactValuesByName userReconcilersByUser;

      user.targets.${lib.removeSuffix ".target" bootReadyTargetName} = {
        description = "Managed user units ready target";
        unitConfig = lib.mkIf migratorEnabled {
          ConditionPathExists = "!${migratorGatePath}";
        };
      };
    };

    services.migrator.managedUnits.dispatchers =
      map (dispatcher: "${dispatcher.name}.service") (builtins.attrValues dispatcherServicesByUser);
  };
}
