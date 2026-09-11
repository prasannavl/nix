{
  lib,
  pkgs,
}: {
  mkModelReconciler = {
    backendServices ? [],
    conditionUser ? null,
    managedTarget,
    name,
    ollamaUrls ? [],
    readyTarget ? null,
    reconcileTriggers ? [],
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
      runtimeEnv =
        {
          OLLAMA_RETIRED_MODELS = lib.concatStringsSep "\n" retiredModels;
        }
        // lib.optionalAttrs (ollamaUrls != []) {
          OLLAMA_URLS = lib.concatStringsSep " " ollamaUrls;
        };
      text = ''
        exec ${lib.getExe pkgs.bash} ${./helper.sh} "$@"
      '';
    };
    conditionConfig = lib.optionalAttrs (conditionUser != null) {
      ConditionUser = conditionUser;
    };
    readyTargets = lib.optional (readyTarget != null) readyTarget;
    workerTimeout = serviceModuleFactory.mkUserTimeoutReadyServiceAttrs timeoutReadySeconds;
    dispatchCommand = "${lib.getExe reconcileModels} dispatch ${workerName}.service ${modelArgs}";
    reconcileCommand = "${lib.getExe reconcileModels} pull ${modelArgs}";
  in {
    assertions = [
      {
        assertion = lib.intersectLists requiredModels retiredModels == [];
        message = "Ollama models cannot be both required and retired";
      }
      {
        assertion = readyTarget != null || backendServices != [];
        message = "Ollama model reconciliation requires a ready target or backend services";
      }
    ];

    systemd.user.services = {
      ${name} = {
        description = "Dispatch declarative Ollama model reconciliation";
        restartIfChanged = true;
        restartTriggers = reconcileTriggers;
        stopIfChanged = false;
        wantedBy = [];
        after = readyTargets ++ ["network-online.target"];
        wants = ["network-online.target"];
        unitConfig =
          conditionConfig
          // lib.optionalAttrs (readyTarget != null) {
            Requires = readyTargets;
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
        after = backendServices ++ readyTargets ++ ["network-online.target"];
        wants = readyTargets ++ ["network-online.target"];
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
