{config, ...}: let
  ai = config.services.ai;
  cacheDir = ai.backends.llamaRouter.runtimesInfo.default.cacheDir;
in {
  # Container definitions only: image, devices, and cache bind. Model pulls,
  # models.ini, lifecycle, and the cache dir are owned by services.ai. Both
  # variants share one GGUF cache; downloads land once and either container
  # serves the same selection.
  services.podman-compose.pvl.instances = {
    # AMD/ROCm variant, mirroring the ollama/ollama-nvidia pair.
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
