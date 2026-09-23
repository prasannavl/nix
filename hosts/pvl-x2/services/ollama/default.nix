{config, ...}: let
  ai = config.services.ai;
  ollamaModelsDir = ai.backends.ollama.modelsDir;
in {
  # Container definitions only: images, devices, and tuning. Model pulls,
  # lifecycle, and the shared models dir are owned by services.ai.
  #
  # Device-class naming: `ollama-rocm` (12434, primary and auto, backing Open
  # WebUI and `x2-rocm`) and `ollama-cpu` (CPU + Vulkan, 11434, manual
  # fallback backing the `x2` client provider). Both publish on the firewall.
  services.podman-compose.pvl.instances = {
    ollama-cpu = rec {
      exposedPorts.main = {
        port = 11434;
        openFirewall = true;
      };

      source = ''
        services:
          ollama-cpu:
            image: docker.io/ollama/ollama:0.34.3
            container_name: ollama-cpu
            ports:
              - "${toString exposedPorts.main.port}:11434"
            volumes:
              - ./ollama_data:/root/.ollama
              - ${ollamaModelsDir}:/models
            environment:
              - OLLAMA_CONTEXT_LENGTH=262144
              - OLLAMA_MODELS=/models
              - OLLAMA_VULKAN=1
              - OLLAMA_FLASH_ATTENTION=1
              - OLLAMA_KV_CACHE_TYPE=q8_0
              - OLLAMA_KEEP_ALIVE=12h
            devices:
              - "/dev/dri:/dev/dri"
            group_add:
              - keep-groups
      '';

      # Model pulls run in pvl-ollama-models-pull; this covers cold image/container startup.
      serviceOverrides.serviceConfig.TimeoutStartSec = "5min";
    };

    ollama-rocm = rec {
      exposedPorts.main = {
        port = 12434;
        openFirewall = true;
      };

      source = ''
        services:
          ollama-rocm:
            image: docker.io/ollama/ollama:0.34.3-rocm
            container_name: ollama-rocm
            ports:
              - "${toString exposedPorts.main.port}:11434"
            volumes:
              - ./ollama_data:/root/.ollama
              - ${ollamaModelsDir}:/models
            environment:
              - OLLAMA_CONTEXT_LENGTH=262144
              - OLLAMA_MODELS=/models
              - OLLAMA_VULKAN=1
              - AMD_VISIBLE_DEVICES=0
              - OLLAMA_FLASH_ATTENTION=1
              - OLLAMA_KV_CACHE_TYPE=q8_0
              - OLLAMA_KEEP_ALIVE=12h
              - ROCR_VISIBLE_DEVICES=0
            devices:
              - "/dev/kfd:/dev/kfd"
              - "/dev/dri:/dev/dri"
            group_add:
              - keep-groups
      '';

      serviceOverrides.serviceConfig.TimeoutStartSec = "5min";
    };
  };
}
