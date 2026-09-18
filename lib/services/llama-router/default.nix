{
  lib,
  pkgs,
}: {
  mkModelReconciler = {
    backendServices ? [],
    cacheDir,
    conditionUser ? null,
    globalPreset ? {},
    managedTarget,
    modelPresets ? {},
    name,
    readyTarget ? null,
    reconcileTriggers ? [],
    requiredModels,
    retiredModels ? [],
    routerUrls ? [],
    timeoutReadySeconds,
  }: let
    serviceModuleFactory = import ../../flake/service-module.nix;
    workerName = "${name}-load";
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
          LLAMA_ROUTER_CACHE_DIR = cacheDir;
          LLAMA_ROUTER_RETIRED_MODELS = lib.concatStringsSep "\n" retiredModels;
        }
        // lib.optionalAttrs (routerUrls != []) {
          LLAMA_ROUTER_URLS = lib.concatStringsSep " " routerUrls;
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
    reconcileCommand = "${lib.getExe reconcileModels} load ${modelArgs}";

    # Router models are Hugging Face references ("org/repo" or "org/repo:tag");
    # the repo part also maps onto the HF cache directory that retirement
    # pruning removes, so the shape is validated here and in the helper.
    modelRefPattern = "^[^/ \t]+/[^/ \t]+(:[^/ \t]+)?$";
    presetKeyPattern = "^[A-Za-z0-9][A-Za-z0-9._-]*$";
    presetEntries =
      lib.mapAttrsToList (key: value: {inherit key value;}) globalPreset
      ++ lib.concatMap (
        model:
          lib.mapAttrsToList (key: value: {inherit key value;}) (modelPresets.${model} or {})
      )
      requiredModels;
    renderPresetSection = name: attrs:
      "[${name}]\n"
      + lib.concatStrings (lib.mapAttrsToList (key: value: "${key} = ${value}\n") attrs);
    # Preset section names use the full Hugging Face reference so they merge
    # with the cache-scanned entries the router already knows; `hf` makes the
    # section resolvable before the model has ever been downloaded.
    modelsPresetIni =
      lib.optionalString (globalPreset != {}) ((renderPresetSection "*" globalPreset) + "\n")
      + lib.concatStrings (
        map (
          model:
            renderPresetSection model ({hf = model;} // (modelPresets.${model} or {}))
        )
        requiredModels
      );
  in {
    assertions = [
      {
        assertion = lib.all (model: lib.match modelRefPattern model != null) requiredModels;
        message = "llama-router required models must be Hugging Face references (org/repo or org/repo:tag)";
      }
      {
        assertion = lib.all (model: lib.match modelRefPattern model != null) retiredModels;
        message = "llama-router retired models must be Hugging Face references (org/repo or org/repo:tag)";
      }
      {
        assertion = lib.intersectLists requiredModels retiredModels == [];
        message = "llama-router models cannot be both required and retired";
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
        assertion =
          builtins.all (
            entry:
              builtins.isString entry.value
              && (builtins.stringLength entry.value) > 0
              && !lib.hasInfix "\n" entry.value
              && lib.match presetKeyPattern entry.key != null
          )
          presetEntries;
        message = "llama-router model preset keys must be llama.cpp option names and values non-empty single-line strings";
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
        description = "Reconcile declarative llama-router models";
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
