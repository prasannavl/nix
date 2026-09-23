{...}: {
  # pvl-x2 AI model policy: the shared catalog selection below is the single
  # source for every backend's reconciler (Ollama tags, llama.cpp GGUF refs,
  # model presets). Container definitions stay in ./ollama and
  # ./llama-router.nix; this file only decides what runs and where.
  services.ai = {
    # Full fleet catalog minus gemma4-12b, which this host does not serve.
    models = [
      "nomic-embed-text"
      "gemma4-e2b"
      "gemma4-e4b"
      "gemma4-26b"
      "gemma4-31b"
      "qwen35-08b"
      "qwen35-2b"
      "qwen35-4b"
      "qwen35-9b"
      "qwen38-27b"
      "gpt-oss-20b"
      "ornith15-9b"
      "ornith15-35b-a3b"
      # Ternary preview served by the PrismML fork runtime below.
      "bonsai-2-27b"
    ];
    roles.embedding = "nomic-embed-text";

    # Deployment order is significant: consumer endpoint lists (Open WebUI,
    # LibreChat) are built in this order, so keep ROCm, CPU with CPU last
    # (pvl-x2 has no NVIDIA class). `ports`/`urls` projections preserve it.
    backends = {
      ollama = {
        # Shared model store, mounted read-write by both Ollama containers.
        modelsDir = "/var/lib/pvl/ollama-models";
        deployments = [
          {
            # AMD/ROCm; primary and auto-started. Backs Open WebUI and the
            # `x2-rocm` provider.
            instance = "ollama-rocm";
            lifecycle = "auto";
          }
          {
            # CPU + Vulkan fallback; warmed by hand and backing the `x2`
            # provider on demand.
            instance = "ollama-cpu";
            lifecycle = "manual";
          }
        ];
      };

      # `pvl-x2` is AMD-only, so the llama.cpp backend has CPU and ROCm device
      # classes only. Both are on-demand (`manual`), so a host boot does not
      # pull the GGUF selection until an operator starts a deployment.
      llamaRouter.runtimes = {
        default = {
          idleTimeoutSeconds = 300;
          deployments = [
            {
              instance = "llama-rocm";
              lifecycle = "manual";
            }
            {
              instance = "llama-cpu";
              lifecycle = "manual";
            }
          ];
        };

        # PrismML fork engine for the ternary Bonsai model; separate cache and
        # reconciler so the upstream runtime never scans ternary GGUFs.
        prism = {
          idleTimeoutSeconds = 300;
          deployments = [
            {
              instance = "llama-prism-rocm";
              lifecycle = "manual";
            }
          ];
        };
      };
    };
  };
}
