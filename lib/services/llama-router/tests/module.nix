{pkgs}: let
  lib = pkgs.lib;
  llamaRouterLib = import ../default.nix {inherit lib pkgs;};
  mkReconciler = {
    backendServices ? [],
    globalPreset ? {},
    legacyStateFile ? "/var/lib/test/llama-router.json",
    modelPresets ? {},
    preservedModels ? [],
    readyTarget ? "test-llama-router-ready.target",
    reconcileTriggers ? [],
    requiredModels ? ["test/model:Q4_K_M"],
    routerUrls ? [],
    timeoutReadySeconds ? 900,
  }:
    llamaRouterLib.mkModelReconciler {
      inherit backendServices globalPreset legacyStateFile modelPresets preservedModels readyTarget reconcileTriggers requiredModels routerUrls timeoutReadySeconds;
      managedTarget = "test-managed";
      name = "test-llama-router-models";
    };
  baseline = mkReconciler {
    backendServices = ["test-llama-router.service"];
    reconcileTriggers = ["backend-config"];
  };
  preservation = mkReconciler {
    preservedModels = ["old/model:Q4_K_M"];
  };
  conflict = mkReconciler {
    preservedModels = ["test/model:Q4_K_M"];
  };
  inactiveBackends = mkReconciler {
    backendServices = [
      "test-llama-router.service"
      "test-llama-router-nvidia.service"
    ];
    routerUrls = [
      "http://127.0.0.1:11000"
      "http://127.0.0.1:12000"
    ];
    readyTarget = null;
  };
  missingReadiness = mkReconciler {
    readyTarget = null;
  };
  unknownPreset = mkReconciler {
    modelPresets = {"other/model:Q4_K_M" = {alias = "other:1";};};
  };
  invalidRequiredRef = mkReconciler {
    requiredModels = ["not-a-ref"];
  };
  invalidPresetValue = mkReconciler {
    modelPresets = {"test/model:Q4_K_M" = {alias = 1;};};
  };
  presetIni = mkReconciler {
    globalPreset = {threads = "4";};
    modelPresets = {"test/model:Q4_K_M" = {alias = "test:1";};};
  };
  dispatcher = baseline.systemd.user.services."test-llama-router-models";
  worker = baseline.systemd.user.services."test-llama-router-models-load";
  preservationDispatcher = preservation.systemd.user.services."test-llama-router-models";
  inactiveDispatcher = inactiveBackends.systemd.user.services."test-llama-router-models";
  inactiveWorker = inactiveBackends.systemd.user.services."test-llama-router-models-load";
in
  assert dispatcher.restartIfChanged;
  assert dispatcher.restartTriggers == ["backend-config"];
  assert dispatcher.serviceConfig.RemainAfterExit;
  assert dispatcher.serviceConfig.StateDirectory == "ai/reconciler";
  assert dispatcher.serviceConfig.StateDirectoryMode == "0750";
  assert dispatcher.environment.MODEL_RECONCILER_STATE_NAME == "llama-router.json";
  assert dispatcher.environment.MODEL_RECONCILER_LEGACY_STATE_FILE == "/var/lib/test/llama-router.json";
  assert dispatcher.serviceConfig.ExecStart != preservationDispatcher.serviceConfig.ExecStart;
  assert dispatcher.unitConfig.Requires == ["test-llama-router-ready.target"];
  assert builtins.elem "test-llama-router.service" worker.after;
  assert worker.environment.NIXBOT_TIMEOUT_READY_SECONDS == "900";
  assert worker.serviceConfig.StateDirectory == "ai/reconciler";
  assert worker.serviceConfig.TimeoutStartSec == 900;
  assert !(inactiveDispatcher.unitConfig ? Requires);
  assert builtins.elem "test-llama-router.service" inactiveWorker.after;
  assert builtins.elem "test-llama-router-nvidia.service" inactiveWorker.after;
  assert !(builtins.elem "test-llama-router.service" inactiveWorker.wants);
  assert worker.serviceConfig.ExecStart != inactiveWorker.serviceConfig.ExecStart;
  assert !(builtins.all (entry: entry.assertion) conflict.assertions);
  assert !(builtins.all (entry: entry.assertion) missingReadiness.assertions);
  assert !(builtins.all (entry: entry.assertion) unknownPreset.assertions);
  assert !(builtins.all (entry: entry.assertion) invalidRequiredRef.assertions);
  assert !(builtins.all (entry: entry.assertion) invalidPresetValue.assertions);
  assert presetIni.modelsPresetIni == "[*]\nthreads = 4\n\n[test:1]\nalias = test:1\nhf = test/model:Q4_K_M\n";
    pkgs.runCommand "llama-router-model-reconciler-test" {} ''
      touch "$out"
    ''
