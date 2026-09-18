{...}: {
  # pvl-x2 AI model policy: the shared catalog selection below is the single
  # source for the Ollama reconciler. Container definitions stay in
  # ./ollama; this file only decides what runs and where.
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
      "qwen36-35b-a3b"
      "gpt-oss-20b"
      "ornith15-9b"
      "ornith15-35b-a3b"
    ];
    roles.embedding = "nomic-embed-text";

    backends.ollama = {
      deployments = [
        {
          port = 11434;
          lifecycle = "auto";
        }
      ];
      retiredModels = ["qwen3.6:27b"];
    };
  };
}
