{...}: {
  # pvl-a1 AI model policy: `models` below is the single selection list.
  # A model joins a backend exactly when its catalog entry carries that
  # backend's ref field, so the catalog schema is the source of truth for
  # both Ollama tags and llama.cpp model presets. Container definitions stay
  # in the per-backend service files; this file only decides what runs, on
  # which engine, and where.
  services.ai = {
    models = [
      "nomic-embed-text"
      "gemma4-e2b"
      "gemma4-e4b"
      "qwen35-08b"
      "qwen35-2b"
      "qwen35-4b"
      "qwen35-9b"
      # Ternary preview: PTQ1_0 GGUFs need the PrismML llama.cpp fork, so
      # this entry pins llama.runtime = "prism" and is served only by the
      # prism runtime below.
      "bonsai-2-27b"
    ];
    roles.embedding = "nomic-embed-text";

    # Deployment order is significant: consumer endpoint lists (Open WebUI,
    # LibreChat) are built in this order, so keep ROCm, NVIDIA, CPU with CPU
    # last. `ports`/`urls` projections preserve it.
    backends = {
      ollama = {
        # Shared model store, mounted read-write by every Ollama container:
        # reconciler pulls run through whichever instance's API, and blobs
        # land here once.
        modelsDir = "/var/lib/pvl/ollama-models";
        deployments = [
          {
            instance = "ollama-rocm";
            lifecycle = "auto";
          }
          {
            instance = "ollama-nvidia";
            lifecycle = "manual";
          }
          {
            # CPU + Vulkan fallback; warmed by hand.
            instance = "ollama-cpu";
            lifecycle = "manual";
          }
        ];
      };

      # Device-class llama.cpp deployments. The ROCm variant auto-starts; the
      # NVIDIA and CPU variants are warmed by hand. idleTimeoutSeconds unloads
      # a model's weights/KV cache once it goes unused, so a large resident
      # model is swapped out like Ollama's keep_alive instead of waiting for a
      # fourth-model LRU eviction.
      llamaRouter.runtimes.default = {
        idleTimeoutSeconds = 300;
        deployments = [
          {
            instance = "llama-rocm";
            lifecycle = "auto";
          }
          {
            instance = "llama-nvidia";
            lifecycle = "manual";
          }
          {
            instance = "llama-cpu";
            lifecycle = "manual";
          }
        ];
      };

      # PrismML fork engine for the ternary Bonsai models. Separate cache and
      # reconciler so the default (upstream) router never sees (or tries to
      # load) these GGUFs.
      llamaRouter.runtimes.prism = {
        idleTimeoutSeconds = 300;
        deployments = [
          {
            instance = "llama-prism-rocm";
            lifecycle = "auto";
          }
          {
            instance = "llama-prism-nvidia";
            lifecycle = "manual";
          }
        ];
      };
    };
  };
}
