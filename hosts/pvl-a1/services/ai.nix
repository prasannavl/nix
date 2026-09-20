{...}: {
  # pvl-a1 AI model policy: the shared catalog selection below is the single
  # source for every backend's reconciler (Ollama tags, model presets, Web UI
  # routing). Container definitions stay in the per-backend service files;
  # this file only decides what runs and where.
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
            lifecycle = "auto";
          }
          {
            # Warmed by hand; the reconciler keeps its models current.
            instance = "ollama-nvidia";
            lifecycle = "manual";
          }
        ];
      };

      # Same AMD/NVIDIA pair as Ollama: the ROCm router auto-starts, the
      # CUDA router is warmed by hand. Both share one GGUF cache (module
      # default /var/lib/pvl/ai/llama-router).
      llamaRouter.deployments = [
        {
          lifecycle = "auto";
        }
        {
          instance = "llama-router-nvidia";
          lifecycle = "manual";
        }
      ];
    };
  };
}
