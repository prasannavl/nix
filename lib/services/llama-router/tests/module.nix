{pkgs}: let
  lib = pkgs.lib;
  llamaRouterLib = import ../default.nix {inherit lib pkgs;};
  mkReconciler = {
    backendServices ? [],
    globalPreset ? {},
    modelPresets ? {},
    readyTarget ? "test-llama-router-ready.target",
    reconcileTriggers ? [],
    requiredModels ? ["test/model:Q4_K_M"],
    retiredModels ? [],
    routerUrls ? [],
    timeoutReadySeconds ? 900,
  }:
    llamaRouterLib.mkModelReconciler {
      inherit backendServices globalPreset modelPresets readyTarget reconcileTriggers requiredModels retiredModels routerUrls timeoutReadySeconds;
      cacheDir = "/var/lib/pvl/test/llama-router/cache";
      managedTarget = "test-managed";
      name = "test-llama-router-models";
    };
  baseline = mkReconciler {
    backendServices = ["test-llama-router.service"];
    reconcileTriggers = ["backend-config"];
  };
  retirement = mkReconciler {
    retiredModels = ["old/model:Q4_K_M"];
  };
  conflict = mkReconciler {
    retiredModels = ["test/model:Q4_K_M"];
  };
  inactiveBackends = mkReconciler {
    backendServices = [
      "test-llama-router.service"
      "test-llama-router-nvidia.service"
    ];
    routerUrls = [
      "http://127.0.0.1:11434"
      "http://127.0.0.1:11435"
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
  retirementDispatcher = retirement.systemd.user.services."test-llama-router-models";
  inactiveDispatcher = inactiveBackends.systemd.user.services."test-llama-router-models";
  inactiveWorker = inactiveBackends.systemd.user.services."test-llama-router-models-load";
in
  assert dispatcher.restartIfChanged;
  assert dispatcher.restartTriggers == ["backend-config"];
  assert dispatcher.serviceConfig.RemainAfterExit;
  assert dispatcher.serviceConfig.ExecStart != retirementDispatcher.serviceConfig.ExecStart;
  assert dispatcher.unitConfig.Requires == ["test-llama-router-ready.target"];
  assert builtins.elem "test-llama-router.service" worker.after;
  assert worker.environment.NIXBOT_TIMEOUT_READY_SECONDS == "900";
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
  assert presetIni.modelsPresetIni == "[*]\nthreads = 4\n\n[test/model:Q4_K_M]\nalias = test:1\nhf = test/model:Q4_K_M\n";
    pkgs.runCommand "llama-router-model-reconciler-test" {} ''
      touch "$out"
    ''
