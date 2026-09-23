{...}: {
  # pvl-l5 AI model policy: the shared catalog selection below is the single
  # source for every backend's reconciler (Ollama tags, llama.cpp GGUF refs,
  # model presets, Web UI routing). Container definitions stay in the
  # per-backend service files; this file only decides what runs and where.
  services.ai = {
    models = [
      "nomic-embed-text"
      "gemma4-e2b"
      "gemma4-e4b"
      "qwen35-08b"
      "qwen35-2b"
      "qwen35-4b"
      "qwen35-9b"
      # Ternary preview served by the PrismML fork runtime below.
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
      llamaRouter.runtimes.default = {
        # Unload a model's weights/KV cache after it goes unused, so a large
        # resident model is swapped out like Ollama's keep_alive instead of
        # waiting for a fourth-model LRU eviction.
        idleTimeoutSeconds = 300;
        deployments = [
          {
            # AMD/ROCm router, mirroring the Ollama set: declaratively
            # stopped, started by hand for GPU sessions.
            instance = "llama-rocm";
            lifecycle = "stopped";
          }
          {
            # NVIDIA/CUDA router on the same shared cache.
            instance = "llama-nvidia";
            lifecycle = "stopped";
          }
          {
            # CPU router on the same shared cache; on-demand only.
            instance = "llama-cpu";
            lifecycle = "manual";
          }
        ];
      };

      # PrismML fork engine for the ternary Bonsai models. Separate cache and
      # reconciler so the default (upstream) runtime never scans or loads the
      # ternary GGUFs. Declaratively stopped like the other l5 GPU backends.
      llamaRouter.runtimes.prism = {
        idleTimeoutSeconds = 300;
        deployments = [
          {
            instance = "llama-prism-rocm";
            lifecycle = "stopped";
          }
          {
            instance = "llama-prism-nvidia";
            lifecycle = "stopped";
          }
        ];
      };
    };
  };
}
