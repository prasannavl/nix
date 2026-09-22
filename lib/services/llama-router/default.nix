{
  lib,
  pkgs,
}: let
  presetLib = import ./presets.nix;
in {
  inherit (presetLib) renderModelsPresetIni validModelRef validOptionName validOptionValue validOptions validSectionName;

  mkModelReconciler = {
    backendServices ? [],
    conditionUser ? null,
    globalPreset ? {},
    managedTarget,
    modelPresets ? {},
    name,
    preservedModels ? [],
    readyTarget ? null,
    reconcileTriggers ? [],
    requiredModels,
    routerUrls ? [],
    legacyStateFile ? null,
    stateDirectory ? "ai/reconciler",
    stateName ? "llama-router.json",
    timeoutReadySeconds,
  }: let
    serviceModuleFactory = import ../../flake/service-module.nix;
    modelReconciler = import ../model-reconciler {inherit lib pkgs;};
    stateBinding = modelReconciler.mkStateBinding {inherit legacyStateFile stateDirectory stateName;};
    workerName = "${name}-load";
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
          LLAMA_ROUTER_PRESERVED_MODELS = lib.concatStringsSep "\n" preservedModels;
        }
        // lib.optionalAttrs (routerUrls != []) {
          LLAMA_ROUTER_URLS = lib.concatStringsSep " " routerUrls;
        };
    };
    conditionConfig = lib.optionalAttrs (conditionUser != null) {
      ConditionUser = conditionUser;
    };
    readyTargets = lib.optional (readyTarget != null) readyTarget;
    workerTimeout = serviceModuleFactory.mkUserTimeoutReadyServiceAttrs timeoutReadySeconds;
    dispatchCommand = "${lib.getExe reconcileModels} dispatch ${workerName}.service ${modelArgs}";
    reconcileCommand = "${lib.getExe reconcileModels} load ${modelArgs}";

    presetModels = builtins.filter (model: modelPresets ? ${model}) requiredModels;
    presetName = model: (modelPresets.${model}.alias or model);
    # Presets use client-facing aliases as section names. The exact Hugging
    # Face reference therefore remains available to the router's cache API for
    # independent download and deletion without colliding with the preset.
    modelsPresetIni = presetLib.renderModelsPresetIni {inherit globalPreset modelPresets requiredModels;};
  in {
    assertions =
      stateBinding.assertions
      ++ [
        {
          assertion = lib.all presetLib.validModelRef requiredModels;
          message = "llama-router required models must be Hugging Face references (org/repo or org/repo:tag)";
        }
        {
          assertion = lib.all presetLib.validModelRef preservedModels;
          message = "llama-router preserved models must be Hugging Face references (org/repo or org/repo:tag)";
        }
        {
          assertion = lib.intersectLists requiredModels preservedModels == [];
          message = "llama-router models cannot be both managed and preserved";
        }
        {
          assertion = readyTarget != null || backendServices != [];
          message = "llama-router model reconciliation requires a ready target or backend services";
        }
        {
          assertion = lib.all (model: builtins.elem model requiredModels) (lib.attrNames modelPresets);
          message = "llama-router model presets must reference required models";
        }
        {
          assertion = lib.all (model: presetName model != model) presetModels;
          message = "llama-router model presets require an alias distinct from the managed cache reference";
        }
        {
          assertion = lib.length (lib.unique (map presetName presetModels)) == lib.length presetModels;
          message = "llama-router model preset aliases must be unique";
        }
        {
          assertion = presetLib.validOptions globalPreset && lib.all (model: presetLib.validOptions (modelPresets.${model} or {})) requiredModels;
          message = "llama-router model preset keys must be llama.cpp option names and values non-empty single-line strings";
        }
        {
          assertion = lib.all (model: presetLib.validSectionName (presetName model)) presetModels;
          message = "llama-router model preset aliases must be non-empty single-line INI section names";
        }
      ];

    inherit modelsPresetIni;

    systemd.user.services = {
      ${name} = {
        description = "Dispatch declarative llama-router model reconciliation";
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
        description = "Reconcile declarative llama-router models";
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
