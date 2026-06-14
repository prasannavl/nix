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
    name = "migrator-configured";
    paths = [cfg.package];
    nativeBuildInputs = [pkgs.makeWrapper];
    postBuild = ''
      wrapProgram "$out/bin/migratorctl" --set MIGRATOR_GATE_PATH ${lib.escapeShellArg gatePath}
      wrapProgram "$out/bin/migrator-helper" --set MIGRATOR_GATE_PATH ${lib.escapeShellArg gatePath}
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
  serviceUnitNames = unitSet: builtins.attrNames unitSet;
  systemUnits = cfg.managedUnits.system;
  dispatcherUnits = lib.unique cfg.managedUnits.dispatchers;
  gateSystemService = unitName: unitCfg:
    lib.nameValuePair (unitNameToServiceAttr unitName) (lib.mkIf unitCfg.gateStart {
      after = ["migrator-sync.service"];
      unitConfig.ConditionPathExists = "!${gatePath}";
    });
  orderDispatcher = unitName: _:
    lib.nameValuePair (unitNameToServiceAttr unitName) {
      after = ["migrator-sync.service"];
    };
  manifest = pkgs.writeText "migrator-manifest.json" (
    builtins.toJSON {
      systemUnits =
        lib.mapAttrsToList
        (unit: unitCfg: {
          unit = unit;
          stopOnDrain = unitCfg.stopOnDrain;
          startOnResume = unitCfg.startOnResume;
        })
        systemUnits;
      dispatcherUnits = dispatcherUnits;
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
          assertion = lib.all (unit: lib.hasSuffix ".service" unit) dispatcherUnits;
          message = "services.migration-manager.managedUnits.dispatchers entries must be full .service unit names.";
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
            migrator-apply = {
              description = "Apply runtime migration gate state";
              after = [
                "migrator-sync.service"
                "multi-user.target"
              ];
              serviceConfig = {
                Type = "oneshot";
                Environment = [
                  "MIGRATOR_MANIFEST=${manifest}"
                ];
                ExecStart = "${configuredPackage}/bin/migrator-helper apply";
              };
            };

            migrator-sync = {
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
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                Environment = [
                  "MIGRATOR_MANIFEST=${manifest}"
                  "MIGRATOR_DECLARED_STATE=${cfg.state}"
                ];
                ExecStart = "${configuredPackage}/bin/migrator-helper sync";
                ExecStartPost = "${pkgs.systemd}/bin/systemctl --no-block restart migrator-apply.service";
              };
            };
          }
          // lib.mapAttrs' gateSystemService systemUnits
          // lib.mapAttrs' orderDispatcher (lib.genAttrs dispatcherUnits (_: {}));
      };
    })
  ];
}
