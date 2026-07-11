{
  lib,
  pkgs,
  ...
}: let
  requiredModels = [
    "nomic-embed-text"
    "gemma4:e2b"
    "gemma4:e4b"
    "gemma4:26b"
    "gemma4:31b"
    "qwen3.5:0.8b"
    "qwen3.5:2b"
    "qwen3.5:4b"
    "qwen3.5:9b"
    "qwen3.6:27b"
    "qwen3.6:35b-a3b"
    "gpt-oss:20b"
  ];
  pullRequiredModels = pkgs.writeShellApplication {
    name = "pvl-x2-ollama-pull-required-models";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.jq
    ];
    text = ''
      exec ${lib.getExe pkgs.bash} ${../../../../lib/services/ollama/helper.sh} "$@"
    '';
  };
  requiredModelsStamp = builtins.hashString "sha256" (builtins.toJSON requiredModels);
in {
  config = {
    services.podman-compose.pvl.instances.ollama = rec {
      exposedPorts.main = {
        port = 11434;
        openFirewall = true;
      };

      source = ''
        services:
          ollama:
            image: docker.io/ollama/ollama:0.31.2-rocm
            container_name: ollama
            ports:
              - "${toString exposedPorts.main.port}:11434"
            volumes:
              - ./ollama_data:/root/.ollama
            environment:
              - OLLAMA_VULKAN=1
              - AMD_VISIBLE_DEVICES=0
              - OLLAMA_FLASH_ATTENTION=1
              - OLLAMA_KV_CACHE_TYPE=q8_0
              - OLLAMA_KEEP_ALIVE=12h
              - ROCR_VISIBLE_DEVICES=0
              - OLLAMA_CONTEXT_LENGTH=262144
            devices:
              - "/dev/kfd:/dev/kfd"
              - "/dev/dri:/dev/dri"
            group_add:
              - keep-groups
      '';

      # Model pulls run in pvl-ollama-models; this covers cold image/container startup.
      serviceOverrides.serviceConfig.TimeoutStartSec = "5min";
    };

    systemd.user.services.pvl-ollama-models = {
      description = "Dispatch required pvl-x2 Ollama model pull";
      after = [
        "pvl-ollama-ready.target"
        "network-online.target"
      ];
      wants = [
        "pvl-ollama-ready.target"
        "network-online.target"
      ];
      restartTriggers = [
        pullRequiredModels
        requiredModelsStamp
      ];
      unitConfig = {
        ConditionUser = "pvl";
        Requires = ["pvl-ollama-ready.target"];
      };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${lib.getExe pullRequiredModels} dispatch pvl-ollama-models-worker.service ${lib.escapeShellArgs requiredModels}";
      };
    };

    systemd.user.services.pvl-ollama-models-worker = {
      description = "Pull required pvl-x2 Ollama models";
      after = [
        "pvl-ollama-ready.target"
        "network-online.target"
      ];
      wants = [
        "network-online.target"
      ];
      unitConfig = {
        ConditionUser = "pvl";
        Requires = ["pvl-ollama-ready.target"];
      };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${lib.getExe pullRequiredModels} ${lib.escapeShellArgs requiredModels}";
      };
    };

    systemd.user.targets.pvl-managed-ready = {
      unitConfig = {
        Requires = ["pvl-ollama-models.service"];
        After = ["pvl-ollama-models.service"];
      };
    };
  };
}
