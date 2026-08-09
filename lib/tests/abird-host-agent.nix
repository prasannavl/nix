{pkgs}: let
  lib = pkgs.lib;
  fakeAgent = pkgs.writeShellScriptBin "abird-host-agent" ''
    exit 0
  '';
  resource = "service:demo";
  instanceResource = "instance:demo-instance";
  extraResource = "group:demo";
  transaction = "migration-test";
  holdFileName = "${builtins.hashString "sha256" resource}.json";
  holdFile = "/var/lib/abird-host-agent/holds/${holdFileName}";
  declaredMarker = "/etc/abird-host-agent/declared-holds/${holdFileName}";
  declarationRelease = "/var/lib/abird-host-agent/declaration-releases/${builtins.hashString "sha256" resource}/${builtins.hashString "sha256" transaction}.json";
  hostResource = "host:nixos";
  hostHoldFile = "/var/lib/abird-host-agent/holds/${builtins.hashString "sha256" hostResource}.json";
  evalConfig = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = pkgs.stdenv.hostPlatform.system;
    inherit pkgs;
    modules = [
      ../services/abird-host-agent
      {
        services.abird-host-agent = {
          enable = true;
          package = fakeAgent;
          declaredHolds.${resource} = transaction;
          services.demo = {
            units = [
              {
                scope = "system";
                unit = "demo.service";
              }
              {
                scope = "user";
                user = "operator";
                unit = "demo-user.service";
              }
            ];
            dataPaths = ["/var/lib/demo"];
            operations.seed = ["${pkgs.coreutils}/bin/true" "--seed"];
            transfers.seed = {
              source = "/var/lib/demo-source";
              destination = "/var/lib/demo";
            };
            fileStates.route-target = {
              path = "/var/lib/abird-host-agent/routes/demo";
              content = "target\n";
              reloadServices = [
                {
                  scope = "system";
                  unit = "demo.service";
                }
              ];
            };
          };
          instances.demo-instance.dataPaths = ["/var/lib/demo-instance"];
          extraResources.${extraResource}.operations.inspect = [
            "${pkgs.coreutils}/bin/true"
            "--inspect"
          ];
        };
        systemd = {
          services.demo.serviceConfig.ExecStart = "${pkgs.coreutils}/bin/true";
          targets.demo-ready = {};
          user = {
            services.demo-user.serviceConfig.ExecStart = "${pkgs.coreutils}/bin/true";
            targets.demo-user-ready = {};
          };
        };
        users.users.operator = {
          isNormalUser = true;
          uid = 2001;
        };
      }
      {
        services.abird-host-agent.services.demo = {
          readiness = [
            {
              type = "path";
              path = "/var/lib/demo";
              requirement = "directory";
            }
          ];
          gatedSystemUnits = ["demo-ready.target"];
          gatedUserUnits.operator = ["demo-user-ready.target"];
        };
      }
    ];
  };
  collisionEval = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = pkgs.stdenv.hostPlatform.system;
    inherit pkgs;
    modules = [
      ../services/abird-host-agent
      {
        services.abird-host-agent = {
          enable = true;
          package = fakeAgent;
          services.demo.dataPaths = ["/var/lib/demo"];
          extraResources."service:demo".dataPaths = ["/var/lib/shadow"];
        };
      }
    ];
  };
  collisionResult = builtins.tryEval collisionEval.config.system.build.toplevel;
  rootPathEval = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = pkgs.stdenv.hostPlatform.system;
    inherit pkgs;
    modules = [
      ../services/abird-host-agent
      {
        services.abird-host-agent = {
          enable = true;
          package = fakeAgent;
          services.demo.dataPaths = ["/"];
        };
      }
    ];
  };
  rootPathResult = builtins.tryEval rootPathEval.config.system.build.toplevel;
  unnamedUserEval = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = pkgs.stdenv.hostPlatform.system;
    inherit pkgs;
    modules = [
      ../services/abird-host-agent
      {
        services.abird-host-agent = {
          enable = true;
          package = fakeAgent;
          services.demo.units = [
            {
              scope = "user";
              unit = "demo.service";
            }
          ];
        };
      }
    ];
  };
  unnamedUserResult = builtins.tryEval unnamedUserEval.config.system.build.toplevel;
  config = evalConfig.config;
  conditions = [
    "!${holdFile}"
    "|!${declaredMarker}"
    "|${declarationRelease}"
    "!${hostHoldFile}"
  ];
  holdCommands = config.systemd.services.abird-host-agent-holds.serviceConfig.ExecStart;
  configuredAgent = builtins.head (lib.splitString " " config.systemd.services.abird-host-agent-jobs.serviceConfig.ExecStart);
  configuredRoot = builtins.dirOf (builtins.dirOf configuredAgent);
  resourceManifest = config.environment.etc."abird-host-agent/resources.json".source;
  runuserProgram = lib.getExe' pkgs.util-linux "runuser";
in
  assert !collisionResult.success;
  assert !rootPathResult.success;
  assert !unnamedUserResult.success;
  assert config.systemd.services.demo.unitConfig.ConditionPathExists == conditions;
  assert config.systemd.targets.demo-ready.unitConfig.ConditionPathExists == conditions;
  assert config.systemd.user.services.demo-user.unitConfig.ConditionPathExists == conditions;
  assert config.systemd.user.targets.demo-user-ready.unitConfig.ConditionPathExists == conditions;
  assert builtins.elem "abird-host-agent-holds.service" config.systemd.services.demo.requires;
  assert builtins.elem "incus.service" config.systemd.services.abird-host-agent-holds.after;
  assert builtins.length holdCommands == 2;
  assert lib.hasInfix "_reconcile hold declare" (builtins.head holdCommands);
  assert lib.hasInfix "_reconcile hold apply" (builtins.elemAt holdCommands 1);
  assert config.systemd.paths.abird-host-agent-jobs.pathConfig.PathExists == "/var/lib/abird-host-agent/jobs-wakeup";
  assert config.systemd.services.abird-host-agent-jobs.serviceConfig.Restart == "on-failure";
  assert lib.hasInfix "_reconcile jobs" config.systemd.services.abird-host-agent-jobs.serviceConfig.ExecStart;
  assert config.systemd.services.abird-host-agent-jobs.serviceConfig.TimeoutStartSec == "infinity";
  assert config.environment.etc."abird-host-agent/declared-holds/${holdFileName}".text == "${transaction}\n";
    pkgs.runCommand "abird-host-agent-module-test" {
      nativeBuildInputs = [pkgs.jq];
    } ''
      test -x ${runuserProgram}
      test -x ${configuredRoot}/bin/rsync
      test -x ${configuredRoot}/bin/tar
      grep -F -- ${lib.escapeShellArg "ABIRD_HOST_AGENT_RUNUSER"} ${configuredAgent}
      grep -F -- ${lib.escapeShellArg runuserProgram} ${configuredAgent}
      jq -e '.resources | any(.id == "service:demo" and .services[0].unit == "demo.service")' ${resourceManifest}
      jq -e '.rsync_program == "${pkgs.rsync}/bin/rsync" and .tar_program == "${pkgs.gnutar}/bin/tar"' ${resourceManifest}
      jq -e '.resources | any(.id == "${instanceResource}" and .data_paths == ["/var/lib/demo-instance"])' ${resourceManifest}
      jq -e '.resources | any(.id == "${extraResource}" and .operations.inspect.argv == ["${pkgs.coreutils}/bin/true", "--inspect"])' ${resourceManifest}
      jq -e '.resources | any(.id == "${hostResource}" and (.data_paths | index("/var/lib/demo")) != null and (.data_paths | index("/var/lib/demo-instance")) != null)' ${resourceManifest}
      touch "$out"
    ''
