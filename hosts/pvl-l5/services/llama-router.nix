{
  config,
  lib,
  pkgs,
  ...
}: let
  llamaRouterCacheDir = "/var/lib/pvl/llama-router/cache";
  # The same model set as the Ollama backends, expressed as Hugging Face
  # references (org/repo:quant) for the llama.cpp router; aliases keep the
  # familiar short names for clients.
  requiredModels = [
    "nomic-ai/nomic-embed-text-v1.5-GGUF:Q4_K_M"
    "unsloth/gemma-4-E2B-it-GGUF:Q4_K_M"
    "unsloth/gemma-4-E4B-it-GGUF:Q4_K_M"
    "unsloth/Qwen3.5-0.8B-GGUF:Q4_K_M"
    "unsloth/Qwen3.5-2B-GGUF:Q4_K_M"
    "unsloth/Qwen3.5-4B-GGUF:Q4_K_M"
    "unsloth/Qwen3.5-9B-GGUF:Q4_K_M"
  ];
  modelPresets = {
    "nomic-ai/nomic-embed-text-v1.5-GGUF:Q4_K_M" = {
      alias = "nomic-embed-text";
      embeddings = "true";
    };
    "unsloth/gemma-4-E2B-it-GGUF:Q4_K_M" = {
      alias = "gemma4:e2b";
    };
    "unsloth/gemma-4-E4B-it-GGUF:Q4_K_M" = {
      alias = "gemma4:e4b";
    };
    "unsloth/Qwen3.5-0.8B-GGUF:Q4_K_M" = {
      alias = "qwen3.5:0.8b";
    };
    "unsloth/Qwen3.5-2B-GGUF:Q4_K_M" = {
      alias = "qwen3.5:2b";
    };
    "unsloth/Qwen3.5-4B-GGUF:Q4_K_M" = {
      alias = "qwen3.5:4b";
    };
    "unsloth/Qwen3.5-9B-GGUF:Q4_K_M" = {
      alias = "qwen3.5:9b";
    };
  };
  llamaRouterLib = import ../../../lib/services/llama-router {inherit lib pkgs;};
  llamaRouterPort = config.services.podman-compose.pvl.instances.llama-router.exposedPorts.main.port;
  backendConfigStamp = builtins.hashString "sha256" (
    builtins.toJSON {
      llamaRouter = config.services.podman-compose.pvl.instances.llama-router;
    }
  );
  reconciler = llamaRouterLib.mkModelReconciler {
    backendServices = ["pvl-llama-router.service"];
    cacheDir = llamaRouterCacheDir;
    conditionUser = "pvl";
    managedTarget = "pvl-managed";
    name = "pvl-llama-router-models";
    inherit modelPresets requiredModels;
    reconcileTriggers = [backendConfigStamp];
    routerUrls = ["http://127.0.0.1:${toString llamaRouterPort}"];
    timeoutReadySeconds = 3600;
  };
in {
  config = lib.mkMerge [
    (builtins.removeAttrs reconciler ["modelsPresetIni"])
    {
      systemd.tmpfiles.rules = [
        "d ${llamaRouterCacheDir} 0755 pvl pvl -"
      ];

      services.podman-compose.pvl.instances.llama-router = rec {
        state = "stopped";

        exposedPorts.main = {
          port = 11436;
        };

        source = ''
          services:
            llama-router:
              image: ghcr.io/ggml-org/llama.cpp:server-cuda-v0.4.1
              container_name: llama-router
              command:
                - --models-preset
                - /etc/llama-router/models.ini
              ports:
                - "${toString exposedPorts.main.port}:8080"
              volumes:
                - ./models.ini:/etc/llama-router/models.ini:ro
                - ${llamaRouterCacheDir}:/cache
              environment:
                - LLAMA_CACHE=/cache
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

        files."models.ini".text = reconciler.modelsPresetIni;
      };
    }
  ];
}
