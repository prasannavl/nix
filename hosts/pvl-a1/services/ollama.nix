{
  config,
  lib,
  pkgs,
  ...
}: let
  ollamaModelsDir = "/var/lib/pvl/ollama-models";
  requiredModels = [
    "nomic-embed-text"
    "gemma4:e2b"
    "gemma4:e4b"
    "qwen3.5:0.8b"
    "qwen3.5:2b"
    "qwen3.5:4b"
    "qwen3.5:9b"
  ];
  pullRequiredModels = pkgs.writeShellApplication {
    name = "pvl-a1-ollama-pull-required-models";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.jq
    ];
    text = ''
      exec ${lib.getExe pkgs.bash} ${../../../lib/services/ollama/helper.sh} "$@"
    '';
  };
in {
  systemd.tmpfiles.rules = [
    "d ${ollamaModelsDir} 0755 pvl pvl -"
  ];

  services.podman-compose.pvl.instances = {
    ollama = rec {
      exposedPorts.main = {
        port = 11434;
      };

      source = ''
        services:
          ollama:
            image: ollama/ollama:rocm
            container_name: ollama
            ports:
              - "${toString exposedPorts.main.port}:11434"
            volumes:
              - ./ollama_data:/root/.ollama
              - ${ollamaModelsDir}:/models
            environment:
              - OLLAMA_CONTEXT_LENGTH=131072
              - OLLAMA_MODELS=/models
              - OLLAMA_VULKAN=1
              - AMD_VISIBLE_DEVICES=0
              - OLLAMA_FLASH_ATTENTION=1
              - OLLAMA_KV_CACHE_TYPE=q8_0
              - OLLAMA_KEEP_ALIVE=10m
              - ROCR_VISIBLE_DEVICES=0
            devices:
              - "/dev/kfd:/dev/kfd"
              - "/dev/dri:/dev/dri"
            group_add:
              - keep-groups
      '';

      # Model pulls run in pvl-ollama-models; this covers cold image/container startup.
      serviceOverrides.serviceConfig.TimeoutStartSec = "5min";
    };

    ollama-nvidia = rec {
      autoStart = false;

      exposedPorts.main = {
        port = 11435;
      };

      source = ''
        services:
          ollama:
            image: ollama/ollama:latest
            container_name: ollama-nvidia
            ports:
              - "${toString exposedPorts.main.port}:11434"
            volumes:
              - ./ollama_nvidia_data:/root/.ollama
              - ${ollamaModelsDir}:/models
            environment:
              - OLLAMA_CONTEXT_LENGTH=131072
              - OLLAMA_MODELS=/models
              - OLLAMA_FLASH_ATTENTION=1
              - OLLAMA_KV_CACHE_TYPE=q8_0
              - OLLAMA_KEEP_ALIVE=10m
              - NVIDIA_VISIBLE_DEVICES=all
              - NVIDIA_DRIVER_CAPABILITIES=compute,utility
            deploy:
              resources:
                reservations:
                  devices:
                    - driver: nvidia
                      count: 1
                      capabilities:
                        - gpu
      '';
    };
  };

  systemd.user.services.pvl-ollama-models = {
    description = "Pull required pvl-a1 Ollama models";
    after = [
      "pvl-ollama.service"
      "pvl-ollama-nvidia.service"
      "network-online.target"
    ];
    wants = [
      "network-online.target"
    ];
    unitConfig.ConditionUser = "pvl";
    serviceConfig = {
      Type = "simple";
      RemainAfterExit = true;
      Environment = let
        ollamaPort = config.services.podman-compose.pvl.instances.ollama.exposedPorts.main.port;
        ollamaNvidiaPort = config.services.podman-compose.pvl.instances.ollama-nvidia.exposedPorts.main.port;
      in [
        "OLLAMA_URLS=http://127.0.0.1:${toString ollamaPort} http://127.0.0.1:${toString ollamaNvidiaPort}"
      ];
      ExecStart = "${lib.getExe pullRequiredModels} ${lib.escapeShellArgs requiredModels}";
    };
  };

  systemd.user.timers.pvl-ollama-models-boot = {
    description = "Start pvl-a1 Ollama model pull after boot";
    wantedBy = ["timers.target"];
    unitConfig.ConditionUser = "pvl";
    timerConfig = {
      OnBootSec = "2min";
      Unit = "pvl-ollama-models.service";
    };
  };

  services.systemd-user-manager.instances.pvl-ollama-models = {
    user = "pvl";
    unit = "pvl-ollama-models.service";
    autoStart = false;
    restartTriggers = [
      pullRequiredModels
      config.services.podman-compose.pvl.instances.ollama
      config.services.podman-compose.pvl.instances.ollama-nvidia
      requiredModels
    ];
  };
}
