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
            name = "ollama";
            port = 11434;
            # Declaratively stopped; started by hand for GPU sessions.
            lifecycle = "stopped";
          }
          {
            name = "ollama-nvidia";
            port = 11435;
            lifecycle = "stopped";
          }
        ];
      };
      llamaRouter.deployments = [
        {
          # AMD/ROCm router, mirroring the Ollama pair: declaratively
          # stopped, started by hand for GPU sessions.
          port = 11436;
          lifecycle = "stopped";
        }
        {
          # NVIDIA/CUDA router on the same shared cache.
          name = "llama-router-nvidia";
          port = 11437;
          lifecycle = "stopped";
        }
      ];
    };
  };
}
