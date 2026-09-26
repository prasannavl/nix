{...}: {
  # pvl-a1 AI model policy: `models` below is the single selection list.
  # A model joins a backend exactly when its catalog entry carries that
  # backend's ref field, so the catalog schema is the source of truth for
  # both Ollama tags and llama.cpp model presets. Container definitions stay
  # in the per-backend service files; this file only decides what runs, on
  # which engine, and where.
  services.ai = {
    models = [
      "nomic-embed-text-v15-100m"
      "gemma4-e2b"
      "gemma4-e4b"
      "qwen35-800m"
      "qwen35-2b"
      "qwen35-4b"
      "qwen35-9b"
      # Ternary preview: PTQ1_0 GGUFs need the PrismML llama.cpp fork, so
      # this entry supports only the prism runtime below.
      "bonsai2-27b"
    ];
    roles.embedding = "nomic-embed-text-v15-100m";

    # Deployment order is significant: consumer endpoint lists (Open WebUI,
    # LibreChat) are built in this order. Keep every ROCm runtime first, then
    # every NVIDIA runtime, and CPU last. `ports`/`urls` projections preserve
    # the declaration order.
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
      llamaRouter = {
        defaults.idleTimeoutSeconds = 300;
        deployments = [
          {
            instance = "llama-rocm";
            lifecycle = "auto";
          }
          # PrismML fork deployments use the runtime-derived isolated cache so
          # upstream llama.cpp never scans ternary-only GGUFs.
          {
            instance = "llama-prism-rocm";
            runtime = "prism";
            lifecycle = "auto";
          }
          {
            instance = "llama-nvidia";
            lifecycle = "manual";
          }
          {
            instance = "llama-prism-nvidia";
            runtime = "prism";
            lifecycle = "manual";
          }
          {
            instance = "llama-cpu";
            lifecycle = "manual";
          }
        ];
      };
    };
  };
}
