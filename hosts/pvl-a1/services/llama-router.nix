{config, ...}: let
  ai = config.services.ai;
  cacheDir = ai.backends.llamaRouter.cacheDir;
in {
  # Container definitions only: image, devices, and cache bind. Model pulls,
  # models.ini, lifecycle, and the cache dir are owned by services.ai. Both
  # variants share one GGUF cache; downloads land once and either container
  # serves the same selection.
  services.podman-compose.pvl.instances = {
    # AMD/ROCm variant, auto-started like the Ollama pair's AMD side.
    llama-router = rec {
      exposedPorts.main.port = ai.backends.llamaRouter.portsByName.llama-router;

      source = ''
        services:
          llama-router:
            image: ghcr.io/ggml-org/llama.cpp:server-rocm-v0.4.1
            container_name: llama-router
            command:
              - --models-preset
              - /etc/llama-router/models.ini
            ports:
              - "${toString exposedPorts.main.port}:8080"
            volumes:
              - ./models.ini:/etc/llama-router/models.ini:ro
              - ${cacheDir}:/cache
            environment:
              - LLAMA_CACHE=/cache
              - ROCR_VISIBLE_DEVICES=0
            devices:
              - "/dev/kfd:/dev/kfd"
              - "/dev/dri:/dev/dri"
            group_add:
              - keep-groups
      '';

      # GGUF downloads run in pvl-llama-router-models; this covers cold image
      # and container startup.
      serviceOverrides.serviceConfig.TimeoutStartSec = "10min";
    };

    # NVIDIA/CUDA variant; same models.ini, same shared cache.
    llama-router-nvidia = rec {
      exposedPorts.main.port = ai.backends.llamaRouter.portsByName.llama-router-nvidia;

      source = ''
        services:
          llama-router:
            image: ghcr.io/ggml-org/llama.cpp:server-cuda-v0.4.1
            container_name: llama-router-nvidia
            command:
              - --models-preset
              - /etc/llama-router/models.ini
            ports:
              - "${toString exposedPorts.main.port}:8080"
            volumes:
              - ./models.ini:/etc/llama-router/models.ini:ro
              - ${cacheDir}:/cache
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
    };
  };
}
