{...}: {
  # pvl-l5 AI model policy: the shared catalog selection below is the single
  # source for every backend's reconciler (Ollama tags, llama.cpp GGUF refs,
  # model presets, Web UI routing). Container definitions stay in the
  # per-backend service files; this file only decides what runs and where.
  services.ai = {
    models = [
      "nomic-embed-text-v15-100m"
      "gemma4-e2b"
      "gemma4-e4b"
      "qwen35-800m"
      "qwen35-2b"
      "qwen35-4b"
      "qwen35-9b"
      # Ternary preview served by the PrismML fork runtime below.
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
            # AMD/ROCm; declaratively stopped, started by hand for GPU
            # sessions.
            instance = "ollama-rocm";
            lifecycle = "stopped";
          }
          {
            instance = "ollama-nvidia";
            lifecycle = "stopped";
          }
          {
            # CPU + Vulkan fallback; never auto-started, survives if started
            # by hand.
            instance = "ollama-cpu";
            lifecycle = "manual";
          }
        ];
      };
      llamaRouter = {
        # Unload a model's weights/KV cache after it goes unused, so a large
        # resident model is swapped out like Ollama's keep_alive instead of
        # waiting for a fourth-model LRU eviction.
        defaults.idleTimeoutSeconds = 300;
        deployments = [
          {
            # AMD/ROCm router, mirroring the Ollama set: declaratively stopped,
            # started by hand for GPU sessions.
            instance = "llama-rocm";
            lifecycle = "stopped";
          }
          # PrismML fork deployments use a distinct runtime-derived cache and
          # remain declaratively stopped like the other l5 GPU backends.
          {
            instance = "llama-prism-rocm";
            runtime = "prism";
            lifecycle = "stopped";
          }
          {
            # NVIDIA/CUDA router on the same shared cache.
            instance = "llama-nvidia";
            lifecycle = "stopped";
          }
          {
            instance = "llama-prism-nvidia";
            runtime = "prism";
            lifecycle = "stopped";
          }
          {
            # CPU router on the same shared cache; on-demand only.
            instance = "llama-cpu";
            lifecycle = "manual";
          }
        ];
      };
    };
  };
}
