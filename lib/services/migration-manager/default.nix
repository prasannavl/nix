{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.migration-manager;
  gatePath = cfg.gatePath;
  gateParentDir = builtins.dirOf gatePath;
  configuredPackage = pkgs.symlinkJoin {
    name = "migration-manager-configured";
    paths = [cfg.package];
    nativeBuildInputs = [pkgs.makeWrapper];
    postBuild = ''
      wrapProgram "$out/bin/migration-manager" --set MIGRATION_MANAGER_GATE_PATH ${lib.escapeShellArg gatePath}
      wrapProgram "$out/bin/migration-manager-helper" --set MIGRATION_MANAGER_GATE_PATH ${lib.escapeShellArg gatePath}
    '';
  };
  bootstrapHosts = import ./bootstrap-hosts.nix;
  hostName = config.networking.hostName or "";
  bootstrapEntry = lib.attrByPath [hostName] {} bootstrapHosts;
  bootstrapState =
    bootstrapEntry.state or (
      if bootstrapEntry ? on
      then
        if bootstrapEntry.on
        then "on"
        else "off"
      else null
    );
  unitNameToServiceAttr = unitName: lib.removeSuffix ".service" unitName;
  unitNameToTargetAttr = unitName: lib.removeSuffix ".target" unitName;
  serviceUnitNames = unitSet: builtins.attrNames unitSet;
  targetUnitNames = unitSet: builtins.attrNames unitSet;
  systemUnits = cfg.managedUnits.system;
  userUnitSets = cfg.managedUnits.users;
  userServiceUnits = lib.concatLists (
    lib.mapAttrsToList (
      user: userCfg:
        lib.mapAttrsToList (
          unit: unitCfg:
            {
              user = user;
              unit = unit;
            }
            // unitCfg
        )
        userCfg.services
    )
    userUnitSets
  );
  userTargetUnits = lib.concatLists (
    lib.mapAttrsToList (
      user: userCfg:
        lib.mapAttrsToList (
          target: targetCfg:
            {
              user = user;
              target = target;
            }
            // targetCfg
        )
        userCfg.targets
    )
    userUnitSets
  );
  gateSystemService = unitName: unitCfg:
    lib.nameValuePair (unitNameToServiceAttr unitName) (lib.mkIf unitCfg.gateStart {
      after = ["migration-manager-sync.service"];
      unitConfig.ConditionPathExists = "!${gatePath}";
    });
  gateUserService = unitName: unitCfg:
    lib.nameValuePair (unitNameToServiceAttr unitName) (lib.mkIf unitCfg.gateStart {
      unitConfig.ConditionPathExists = "!${gatePath}";
    });
  gateUserTarget = unitName: unitCfg:
    lib.nameValuePair (unitNameToTargetAttr unitName) (lib.mkIf unitCfg.gateStart {
      unitConfig.ConditionPathExists = "!${gatePath}";
    });
  userServiceGateConfig = lib.mkMerge (
    lib.mapAttrsToList (
      _: userCfg:
        lib.mapAttrs' gateUserService userCfg.services
    )
    userUnitSets
  );
  userTargetGateConfig = lib.mkMerge (
    lib.mapAttrsToList (
      _: userCfg:
        lib.mapAttrs' gateUserTarget userCfg.targets
    )
    userUnitSets
  );
  manifest = pkgs.writeText "migration-manager-manifest.json" (
    builtins.toJSON {
      systemUnits =
        lib.mapAttrsToList
        (unit: unitCfg: {
          unit = unit;
          stopOnDrain = unitCfg.stopOnDrain;
          startOnResume = unitCfg.startOnResume;
        })
        systemUnits;
      userServices =
        map
        (entry: {
          user = entry.user;
          unit = entry.unit;
          stopOnDrain = entry.stopOnDrain;
          startOnResume = entry.startOnResume;
        })
        userServiceUnits;
      userTargets =
        map
        (entry: {
          user = entry.user;
          target = entry.target;
          stopOnDrain = entry.stopOnDrain;
          startOnResume = entry.startOnResume;
        })
        userTargetUnits;
    }
  );
in {
  imports = [
    ./options.nix
  ];

  config = lib.mkMerge [
    (lib.mkIf (bootstrapState != null) {
      services.migration-manager = {
        enable = true;
        state = lib.mkForce bootstrapState;
      };
    })

    (lib.mkIf cfg.enable {
      environment = {
        systemPackages = [configuredPackage];
      };

      assertions = [
        {
          assertion = lib.all (unit: lib.hasSuffix ".service" unit) (serviceUnitNames systemUnits);
          message = "services.migration-manager.managedUnits.system keys must be full .service unit names.";
        }
        {
          assertion =
            lib.all
            (userCfg: lib.all (unit: lib.hasSuffix ".service" unit) (serviceUnitNames userCfg.services))
            (builtins.attrValues userUnitSets);
          message = "services.migration-manager.managedUnits.users.<user>.services keys must be full .service unit names.";
        }
        {
          assertion =
            lib.all
            (userCfg: lib.all (unit: lib.hasSuffix ".target" unit) (targetUnitNames userCfg.targets))
            (builtins.attrValues userUnitSets);
          message = "services.migration-manager.managedUnits.users.<user>.targets keys must be full .target unit names.";
        }
        {
          assertion = lib.all (user: builtins.hasAttr user config.users.users) (builtins.attrNames userUnitSets);
          message = "services.migration-manager.managedUnits.users keys must refer to users declared in users.users.";
        }
        {
          assertion =
            lib.all
            (
              user:
                (! builtins.hasAttr user config.users.users)
                || config.users.users.${user}.uid != null
            )
            (builtins.attrNames userUnitSets);
          message = "services.migration-manager.managedUnits.users entries must have non-null users.users.<user>.uid.";
        }
      ];

      systemd = {
        tmpfiles.rules =
          [
            "d ${gateParentDir} 0755 root root -"
          ]
          ++ lib.optionals (cfg.state == "on") [
            "f ${gatePath} 0644 root root -"
          ]
          ++ lib.optionals (cfg.state == "off") [
            "r ${gatePath} - - - -"
          ];

        services =
          {
            migration-manager-apply = {
              description = "Apply runtime migration gate state";
              after = [
                "migration-manager-sync.service"
                "multi-user.target"
              ];
              serviceConfig = {
                Type = "oneshot";
                Environment = [
                  "MIGRATION_MANAGER_MANIFEST=${manifest}"
                ];
                ExecStart = "${configuredPackage}/bin/migration-manager-helper apply";
              };
            };

            migration-manager-sync = {
              description = "Sync declared migration gate state";
              wantedBy = ["multi-user.target"];
              after = ["local-fs.target"];
              before = ["multi-user.target"];
              restartTriggers = [
                manifest
                cfg.state
                configuredPackage
              ];
              restartIfChanged = true;
              stopIfChanged = true;
              serviceConfig =
                {
                  Type = "oneshot";
                  RemainAfterExit = true;
                  Environment = [
                    "MIGRATION_MANAGER_MANIFEST=${manifest}"
                    "MIGRATION_MANAGER_DECLARED_STATE=${cfg.state}"
                  ];
                  ExecStart = "${configuredPackage}/bin/migration-manager-helper sync";
                }
                // lib.optionalAttrs (cfg.state != "runtime") {
                  ExecStartPost = "${pkgs.systemd}/bin/systemctl --no-block restart migration-manager-apply.service";
                };
            };
          }
          // lib.mapAttrs' gateSystemService systemUnits;

        user = {
          services = userServiceGateConfig;
          targets = userTargetGateConfig;
        };
      };
    })
  ];
}
