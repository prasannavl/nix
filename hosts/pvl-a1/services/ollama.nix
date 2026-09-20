{config, ...}: let
  ai = config.services.ai;
  ollamaModelsDir = ai.backends.ollama.modelsDir;
in {
  # Container definitions only: images, devices, and tuning. Model pulls,
  # lifecycle, and the shared models dir are owned by services.ai.
  services.podman-compose.pvl.instances = {
    ollama = rec {
      exposedPorts.main.port = 11434;

      source = ''
        services:
          ollama:
            image: docker.io/ollama/ollama:0.34.2-rocm
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
      exposedPorts.main.port = 11435;

      source = ''
        services:
          ollama:
            image: docker.io/ollama/ollama:0.34.2
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
