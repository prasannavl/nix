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
      # prism router pair below.
      "bonsai-2-27b"
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
      # CUDA router is warmed by hand. idleTimeoutSeconds unloads a model's
      # weights/KV cache once it goes unused, so a large resident model is
      # swapped out like Ollama's keep_alive instead of waiting for a
      # fourth-model LRU eviction.
      llamaRouter.runtimes.default = {
        idleTimeoutSeconds = 300;
        deployments = [
          {
            lifecycle = "auto";
          }
          {
            instance = "llama-router-nvidia";
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
            instance = "llama-router-prism";
            lifecycle = "auto";
          }
          {
            instance = "llama-router-prism-nvidia";
            lifecycle = "manual";
          }
        ];
      };
    };
  };
}
