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
  ollamaLib = import ../../../lib/services/ollama {inherit lib pkgs;};
  ollamaPort = config.services.podman-compose.pvl.instances.ollama.exposedPorts.main.port;
  ollamaNvidiaPort = config.services.podman-compose.pvl.instances.ollama-nvidia.exposedPorts.main.port;
  backendConfigStamp = builtins.hashString "sha256" (
    builtins.toJSON {
      ollama = config.services.podman-compose.pvl.instances.ollama;
      ollamaNvidia = config.services.podman-compose.pvl.instances.ollama-nvidia;
    }
  );
in {
  config = lib.mkMerge [
    (ollamaLib.mkModelReconciler {
      backendServices = [
        "pvl-ollama.service"
        "pvl-ollama-nvidia.service"
      ];
      conditionUser = "pvl";
      managedTarget = "pvl-managed";
      name = "pvl-ollama-models";
      ollamaUrls = [
        "http://127.0.0.1:${toString ollamaPort}"
        "http://127.0.0.1:${toString ollamaNvidiaPort}"
      ];
      readyTarget = "pvl-ollama-ready.target";
      reconcileTriggers = [backendConfigStamp];
      timeoutReadySeconds = 3600;
      inherit requiredModels;
    })
    {
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
                image: docker.io/ollama/ollama:0.34.0-rocm
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
                image: docker.io/ollama/ollama:0.34.0
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
    }
  ];
}
