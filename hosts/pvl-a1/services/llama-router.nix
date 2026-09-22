{
  config,
  pkgs,
  ...
}: let
  ai = config.services.ai;
  defaultCache = ai.backends.llamaRouter.runtimesInfo.default.cacheDir;
  prismCache = ai.backends.llamaRouter.runtimesInfo.prism.cacheDir;
in {
  # Container definitions only: image, devices, and cache bind. Model pulls,
  # models.ini, lifecycle, and cache dirs are owned by services.ai.
  #
  # Two engines run side by side. The `default` pair uses stock ggml-org
  # images and shares one GGUF cache. The `prism` pair uses the same images
  # but bind-mounts the PrismML fork over /app, so its llama-server and
  # ggml libraries are the fork build; its cache is separate, so the default
  # router never scans (or tries to load) ternary GGUFs it cannot read. Prism
  # ports sit one above their default-engine counterpart so the pairs stay
  # adjacent (11000/11001 ROCm, 12000/12001 CUDA).
  services.podman-compose.pvl.instances = {
    # AMD/ROCm variant, auto-started like the Ollama pair's AMD side.
    llama-router = rec {
      exposedPorts.main.port = 11000;

      source = ''
        services:
          llama-router:
            image: ghcr.io/ggml-org/llama.cpp:server-rocm-v0.4.1
            container_name: llama-router
            # Three resident workers let the embedding model co-reside with
            # up to two chat models (an /embeddings request no longer
            # LRU-evicts a chat worker); the poll = 0 presets plus
            # sleep-idle-seconds keep idle workers off the GPU.
            command:
              - --models-preset
              - /etc/llama-router/models.ini
              - --models-max
              - "3"
            ports:
              - "${toString exposedPorts.main.port}:8080"
            volumes:
              - ./models.ini:/etc/llama-router/models.ini:ro
              - ${defaultCache}:/cache
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
      exposedPorts.main.port = 12000;

      source = ''
        services:
          llama-router:
            image: ghcr.io/ggml-org/llama.cpp:server-cuda-v0.4.1
            container_name: llama-router-nvidia
            # Three resident workers for the same co-residency reason as the
            # AMD variant; the poll = 0 presets plus sleep-idle-seconds keep
            # idle workers from busy-polling the GPU.
            command:
              - --models-preset
              - /etc/llama-router/models.ini
              - --models-max
              - "3"
            ports:
              - "${toString exposedPorts.main.port}:8080"
            volumes:
              - ./models.ini:/etc/llama-router/models.ini:ro
              - ${defaultCache}:/cache
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

    # PrismML fork, ROCm/CUDA pair. The fork directory (llama-server plus its
    # shared libraries, RUNPATH $ORIGIN) is mounted over /app; the container's
    # ROCm 7.2.1 / CUDA 12.8 userspace is an exact match for the builds.
    llama-router-prism = rec {
      exposedPorts.main.port = 11001;

      source = ''
        services:
          llama-router-prism:
            image: ghcr.io/ggml-org/llama.cpp:server-rocm-v0.4.1
            container_name: llama-router-prism
            # Fork engine for ternary Bonsai; same worker model as the
            # default engine.
            command:
              - --models-preset
              - /etc/llama-router/models.ini
              - --models-max
              - "3"
            ports:
              - "${toString exposedPorts.main.port}:8080"
            volumes:
              - ./models.ini:/etc/llama-router/models.ini:ro
              - ${prismCache}:/cache
              # Swap in the fork build: binary and libraries.
              - ${pkgs.prism-llama-cpp-rocm}:/app:ro
            environment:
              - LLAMA_CACHE=/cache
              - ROCR_VISIBLE_DEVICES=0
            devices:
              - "/dev/kfd:/dev/kfd"
              - "/dev/dri:/dev/dri"
            group_add:
              - keep-groups
      '';

      serviceOverrides.serviceConfig.TimeoutStartSec = "10min";
    };

    llama-router-prism-nvidia = rec {
      exposedPorts.main.port = 12001;

      source = ''
        services:
          llama-router-prism:
            image: ghcr.io/ggml-org/llama.cpp:server-cuda-v0.4.1
            container_name: llama-router-prism-nvidia
            command:
              - --models-preset
              - /etc/llama-router/models.ini
              - --models-max
              - "3"
            ports:
              - "${toString exposedPorts.main.port}:8080"
            volumes:
              - ./models.ini:/etc/llama-router/models.ini:ro
              - ${prismCache}:/cache
              - ${pkgs.prism-llama-cpp-cuda}:/app:ro
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
