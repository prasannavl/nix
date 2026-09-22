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
    ];
    roles.embedding = "nomic-embed-text";

    backends = {
      ollama = {
        # Shared model store, mounted read-write by both Ollama containers:
        # reconciler pulls run through either instance's API and land here.
        modelsDir = "/var/lib/pvl/ollama-models";
        deployments = [
          {
            instance = "ollama";
            # Declaratively stopped; started by hand for GPU sessions.
            lifecycle = "stopped";
          }
          {
            instance = "ollama-nvidia";
            lifecycle = "stopped";
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
            # AMD/ROCm router, mirroring the Ollama pair: declaratively
            # stopped, started by hand for GPU sessions.
            lifecycle = "stopped";
          }
          {
            # NVIDIA/CUDA router on the same shared cache.
            instance = "llama-router-nvidia";
            lifecycle = "stopped";
          }
        ];
      };
    };
  };
}
