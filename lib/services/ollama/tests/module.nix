{pkgs}: let
  lib = pkgs.lib;
  ollamaLib = import ../default.nix {inherit lib pkgs;};
  mkReconciler = retiredModels: timeoutReadySeconds:
    ollamaLib.mkModelReconciler {
      managedTarget = "test-managed";
      name = "test-ollama-models";
      readyTarget = "test-ollama-ready.target";
      requiredModels = ["new:1"];
      retiredModels = retiredModels;
      inherit timeoutReadySeconds;
    };
  baseline = mkReconciler [] 900;
  retirement = mkReconciler ["old:1"] 900;
  conflict = mkReconciler ["new:1"] 900;
  dispatcher = baseline.systemd.user.services."test-ollama-models";
  worker = baseline.systemd.user.services."test-ollama-models-pull";
  retirementDispatcher = retirement.systemd.user.services."test-ollama-models";
in
  assert dispatcher.restartIfChanged;
  assert dispatcher.serviceConfig.ExecStart != retirementDispatcher.serviceConfig.ExecStart;
  assert worker.environment.NIXBOT_TIMEOUT_READY_SECONDS == "900";
  assert worker.serviceConfig.TimeoutStartSec == 900;
  assert !(builtins.all (entry: entry.assertion) conflict.assertions);
    pkgs.runCommand "ollama-model-reconciler-test" {} ''
      touch "$out"
    ''
