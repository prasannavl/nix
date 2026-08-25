{
  lib,
  pkgs,
}: {
  mkModelReconciler = {
    conditionUser ? null,
    managedTarget,
    name,
    readyTarget,
    requiredModels,
    retiredModels ? [],
    timeoutReadySeconds,
  }: let
    serviceModuleFactory = import ../../flake/service-module.nix;
    workerName = "${name}-pull";
    modelArgs = lib.escapeShellArgs requiredModels;
    reconcileModels = pkgs.writeShellApplication {
      name = "${name}-reconcile";
      runtimeInputs = [
        pkgs.coreutils
        pkgs.curl
        pkgs.jq
      ];
      runtimeEnv.OLLAMA_RETIRED_MODELS = lib.concatStringsSep "\n" retiredModels;
      text = ''
        exec ${lib.getExe pkgs.bash} ${./helper.sh} "$@"
      '';
    };
    conditionConfig = lib.optionalAttrs (conditionUser != null) {
      ConditionUser = conditionUser;
    };
    workerTimeout = serviceModuleFactory.mkUserTimeoutReadyServiceAttrs timeoutReadySeconds;
    dispatchCommand = "${lib.getExe reconcileModels} dispatch ${workerName}.service ${modelArgs}";
    reconcileCommand = "${lib.getExe reconcileModels} pull ${modelArgs}";
  in {
    assertions = [
      {
        assertion = lib.intersectLists requiredModels retiredModels == [];
        message = "Ollama models cannot be both required and retired";
      }
    ];

    systemd.user.services = {
      ${name} = {
        description = "Dispatch declarative Ollama model reconciliation";
        restartIfChanged = true;
        stopIfChanged = false;
        wantedBy = [];
        after = [
          readyTarget
          "network-online.target"
        ];
        wants = ["network-online.target"];
        unitConfig =
          conditionConfig
          // {
            Requires = [readyTarget];
          };
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = dispatchCommand;
        };
      };

      ${workerName} = {
        description = "Reconcile declarative Ollama models";
        inherit (workerTimeout) environment;
        restartIfChanged = false;
        stopIfChanged = false;
        wantedBy = [];
        after = [
          readyTarget
          "network-online.target"
        ];
        wants = [
          readyTarget
          "network-online.target"
        ];
        unitConfig = conditionConfig;
        serviceConfig =
          workerTimeout.serviceConfig
          // {
            Type = "oneshot";
            ExecStart = reconcileCommand;
          };
      };
    };

    systemd.user.targets.${managedTarget} = {
      wants = ["${name}.service"];
      after = ["${name}.service"];
    };
  };
}
