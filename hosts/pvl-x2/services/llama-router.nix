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
  # models.ini, lifecycle, and the cache dirs are owned by services.ai.
  #
  # Device-class naming: `llama-cpu`, `llama-rocm`, and `llama-prism-rocm`.
  # `pvl-x2` is AMD-only, so there is no NVIDIA device class here.
  #
  # Ports follow `deviceBase + runtimeSlot`: CPU 11000, ROCm 12000, with the
  # prism runtime one slot higher (`12001`). The default set shares one GGUF
  # cache; the prism runtime uses its own so the upstream runtime never scans
  # ternary GGUFs.
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
              - ${defaultCache}:/cache
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
            # up to two chat models; the poll = 0 presets plus
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

      serviceOverrides.serviceConfig.TimeoutStartSec = "10min";
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
  };
}
