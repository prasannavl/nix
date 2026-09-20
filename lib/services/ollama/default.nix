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
    preservedModels ? [],
    readyTarget ? null,
    reconcileTriggers ? [],
    requiredModels,
    legacyStateFile ? null,
    stateDirectory ? "ai/reconciler",
    stateName ? "ollama.json",
    timeoutReadySeconds,
  }: let
    serviceModuleFactory = import ../../flake/service-module.nix;
    modelReconciler = import ../model-reconciler {inherit lib pkgs;};
    stateBinding = modelReconciler.mkStateBinding {inherit legacyStateFile stateDirectory stateName;};
    workerName = "${name}-pull";
    modelArgs = lib.escapeShellArgs requiredModels;
    reconcileModels = modelReconciler.mkApplication {
      helper = ./helper.sh;
      name = "${name}-reconcile";
      runtimeInputs = [
        pkgs.coreutils
        pkgs.curl
        pkgs.jq
      ];
      runtimeEnv =
        {
          OLLAMA_PRESERVED_MODELS = lib.concatStringsSep "\n" preservedModels;
        }
        // lib.optionalAttrs (ollamaUrls != []) {
          OLLAMA_URLS = lib.concatStringsSep " " ollamaUrls;
        };
    };
    conditionConfig = lib.optionalAttrs (conditionUser != null) {
      ConditionUser = conditionUser;
    };
    readyTargets = lib.optional (readyTarget != null) readyTarget;
    workerTimeout = serviceModuleFactory.mkUserTimeoutReadyServiceAttrs timeoutReadySeconds;
    dispatchCommand = "${lib.getExe reconcileModels} dispatch ${workerName}.service ${modelArgs}";
    reconcileCommand = "${lib.getExe reconcileModels} pull ${modelArgs}";
  in {
    assertions =
      stateBinding.assertions
      ++ [
        {
          assertion = lib.intersectLists requiredModels preservedModels == [];
          message = "Ollama models cannot be both managed and preserved";
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
        environment = stateBinding.environment;
        after = readyTargets ++ ["network-online.target"];
        wants = ["network-online.target"];
        unitConfig =
          conditionConfig
          // lib.optionalAttrs (readyTarget != null) {
            Requires = readyTargets;
          };
        serviceConfig =
          stateBinding.serviceConfig
          // {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = dispatchCommand;
          };
      };

      ${workerName} = {
        description = "Reconcile declarative Ollama models";
        environment = workerTimeout.environment // stateBinding.environment;
        restartIfChanged = false;
        stopIfChanged = false;
        wantedBy = [];
        after = backendServices ++ readyTargets ++ ["network-online.target"];
        wants = readyTargets ++ ["network-online.target"];
        unitConfig = conditionConfig;
        serviceConfig =
          workerTimeout.serviceConfig
          // stateBinding.serviceConfig
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
