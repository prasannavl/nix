{pkgs}: let
  lib = pkgs.lib;
  ollamaLib = import ../default.nix {inherit lib pkgs;};
  mkReconciler = {
    backendServices ? [],
    ollamaUrls ? [],
    readyTarget ? "test-ollama-ready.target",
    reconcileTriggers ? [],
    retiredModels ? [],
    timeoutReadySeconds ? 900,
  }:
    ollamaLib.mkModelReconciler {
      inherit backendServices ollamaUrls readyTarget reconcileTriggers retiredModels timeoutReadySeconds;
      managedTarget = "test-managed";
      name = "test-ollama-models";
      requiredModels = ["new:1"];
    };
  baseline = mkReconciler {
    backendServices = ["test-ollama.service"];
    reconcileTriggers = ["backend-config"];
  };
  retirement = mkReconciler {
    retiredModels = ["old:1"];
  };
  conflict = mkReconciler {
    retiredModels = ["new:1"];
  };
  inactiveBackends = mkReconciler {
    backendServices = [
      "test-ollama.service"
      "test-ollama-nvidia.service"
    ];
    ollamaUrls = [
      "http://127.0.0.1:11434"
      "http://127.0.0.1:11435"
    ];
    readyTarget = null;
  };
  missingReadiness = mkReconciler {
    readyTarget = null;
  };
  dispatcher = baseline.systemd.user.services."test-ollama-models";
  worker = baseline.systemd.user.services."test-ollama-models-pull";
  retirementDispatcher = retirement.systemd.user.services."test-ollama-models";
  inactiveDispatcher = inactiveBackends.systemd.user.services."test-ollama-models";
  inactiveWorker = inactiveBackends.systemd.user.services."test-ollama-models-pull";
in
  assert dispatcher.restartIfChanged;
  assert dispatcher.restartTriggers == ["backend-config"];
  assert dispatcher.serviceConfig.RemainAfterExit;
  assert dispatcher.serviceConfig.ExecStart != retirementDispatcher.serviceConfig.ExecStart;
  assert dispatcher.unitConfig.Requires == ["test-ollama-ready.target"];
  assert builtins.elem "test-ollama.service" worker.after;
  assert worker.environment.NIXBOT_TIMEOUT_READY_SECONDS == "900";
  assert worker.serviceConfig.TimeoutStartSec == 900;
  assert !(inactiveDispatcher.unitConfig ? Requires);
  assert builtins.elem "test-ollama.service" inactiveWorker.after;
  assert builtins.elem "test-ollama-nvidia.service" inactiveWorker.after;
  assert !(builtins.elem "test-ollama.service" inactiveWorker.wants);
  assert worker.serviceConfig.ExecStart != inactiveWorker.serviceConfig.ExecStart;
  assert !(builtins.all (entry: entry.assertion) conflict.assertions);
  assert !(builtins.all (entry: entry.assertion) missingReadiness.assertions);
    pkgs.runCommand "ollama-model-reconciler-test" {} ''
      touch "$out"
    ''
