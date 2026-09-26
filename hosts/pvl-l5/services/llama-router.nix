{
  config,
  pkgs,
  ...
}: let
  ai = config.services.ai;
  cacheDir = ai.backends.llamaRouter.deploymentsInfo.llama-rocm.cacheDir;
  prismCache = ai.backends.llamaRouter.deploymentsInfo.llama-prism-rocm.cacheDir;
in {
  # Container definitions only: image, devices, and cache bind. Model pulls,
  # models.ini, lifecycle, and the cache dirs are owned by services.ai.
  #
  # Device-class naming: `llama-<device>` for the upstream engine and
  # `llama-prism-<device>` for the PrismML fork. Ports follow
  # `deviceBase + runtimeSlot`: CPU 11000, ROCm 12000, NVIDIA 13000, with the
  # prism runtime one slot higher. The default set shares one GGUF cache; the
  # prism pair uses its own so the upstream runtime never scans ternary GGUFs.
  services.podman-compose.pvl.instances = {
    # CPU-only variant; stock CPU image, no accelerator.
    llama-cpu = rec {
      exposedPorts.main.port = 11000;

      source = ''
        services:
          llama-cpu:
            image: ghcr.io/ggml-org/llama.cpp:server-v0.4.1
            container_name: llama-cpu
            # Two resident workers cover the embedding model plus one chat
            # model without holding three CPU model sets in system RAM.
            command:
              - --models-preset
              - /etc/llama-router/models.ini
              - --models-max
              - "2"
            ports:
              - "${toString exposedPorts.main.port}:8080"
            volumes:
              - ./models.ini:/etc/llama-router/models.ini:ro
              - ${cacheDir}:/cache
            environment:
              - LLAMA_CACHE=/cache
      '';

      serviceOverrides.serviceConfig.TimeoutStartSec = "10min";
    };

    # AMD/ROCm variant, mirroring the ollama-rocm deployment.
    llama-rocm = rec {
      exposedPorts.main.port = 12000;

      source = ''
        services:
          llama-rocm:
            image: ghcr.io/ggml-org/llama.cpp:server-rocm-v0.4.1
            container_name: llama-rocm
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
              - ${cacheDir}:/cache
            environment:
              - LLAMA_CACHE=/cache
            devices:
              - "/dev/kfd:/dev/kfd"
              - "/dev/dri:/dev/dri"
            group_add:
              - keep-groups
      '';
    };

    # NVIDIA/CUDA variant; same models.ini, same shared cache.
    llama-nvidia = rec {
      exposedPorts.main.port = 13000;

      source = ''
        services:
          llama-nvidia:
            image: ghcr.io/ggml-org/llama.cpp:server-cuda-v0.4.1
            container_name: llama-nvidia
            # Three resident workers for the same co-residency reason as the
            # ROCm variant; the poll = 0 presets plus sleep-idle-seconds keep
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

    # PrismML fork, ROCm variant. The fork directory (llama-server plus its
    # shared libraries, RUNPATH $ORIGIN) is mounted over /app; the container's
    # ROCm userspace is an exact match for the build.
    llama-prism-rocm = rec {
      exposedPorts.main.port = 12001;

      source = ''
        services:
          llama-prism-rocm:
            image: ghcr.io/ggml-org/llama.cpp:server-rocm-v0.4.1
            container_name: llama-prism-rocm
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

    # PrismML fork, CUDA variant.
    llama-prism-nvidia = rec {
      exposedPorts.main.port = 13001;

      source = ''
        services:
          llama-prism-nvidia:
            image: ghcr.io/ggml-org/llama.cpp:server-cuda-v0.4.1
            container_name: llama-prism-nvidia
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
