{
  # The fleet-wide AI model catalog. Keys are stable attr names used by host
  # selections (services.ai.models); each entry carries the model's
  # client-facing id plus per-backend references:
  #   id     - the shared, client-facing model id (Ollama tag and llama alias)
  #   hf     - the upstream Hugging Face safetensors repo (vLLM/SGLang)
  #   ollama - the Ollama tag served by Ollama backends
  #   llama  - the GGUF reference (org/repo:quant) served by llama.cpp router
  # pinned  - surfaced as a default-pinned model by Web UI consumers
  # GGUF conversions live in separate repos under different orgs (unsloth,
  # ornith-ai, nomic-ai, ggml-org), so the mapping is declared, not derived.
  nomic-embed-text = {
    id = "nomic-embed-text";
    hf = "nomic-ai/nomic-embed-text-v1.5";
    ollama = "nomic-embed-text";
    llama = "nomic-ai/nomic-embed-text-v1.5-GGUF:Q4_K_M";
  };
  gemma4-e2b = {
    id = "gemma4:e2b";
    hf = "google/gemma-4-E2B-it";
    ollama = "gemma4:e2b";
    llama = "unsloth/gemma-4-E2B-it-GGUF:Q4_K_M";
    pinned = true;
  };
  gemma4-e4b = {
    id = "gemma4:e4b";
    hf = "google/gemma-4-E4B-it";
    ollama = "gemma4:e4b";
    llama = "unsloth/gemma-4-E4B-it-GGUF:Q4_K_M";
    pinned = true;
  };
  gemma4-12b = {
    id = "gemma4:12b";
    hf = "google/gemma-4-12B-it";
    ollama = "gemma4:12b";
    llama = "unsloth/gemma-4-12b-it-GGUF:Q4_K_M";
    pinned = true;
  };
  gemma4-26b = {
    id = "gemma4:26b";
    hf = "google/gemma-4-26B-A4B-it";
    ollama = "gemma4:26b";
    llama = "unsloth/gemma-4-26B-A4B-it-GGUF:Q4_K_M";
    pinned = true;
  };
  gemma4-31b = {
    id = "gemma4:31b";
    hf = "google/gemma-4-31B-it";
    ollama = "gemma4:31b";
    llama = "unsloth/gemma-4-31B-it-GGUF:Q4_K_M";
  };
  qwen35-08b = {
    id = "qwen3.5:0.8b";
    hf = "Qwen/Qwen3.5-0.8B";
    ollama = "qwen3.5:0.8b";
    llama = "unsloth/Qwen3.5-0.8B-GGUF:Q4_K_M";
    pinned = true;
  };
  qwen35-2b = {
    id = "qwen3.5:2b";
    hf = "Qwen/Qwen3.5-2B";
    ollama = "qwen3.5:2b";
    llama = "unsloth/Qwen3.5-2B-GGUF:Q4_K_M";
    pinned = true;
  };
  qwen35-4b = {
    id = "qwen3.5:4b";
    hf = "Qwen/Qwen3.5-4B";
    ollama = "qwen3.5:4b";
    llama = "unsloth/Qwen3.5-4B-GGUF:Q4_K_M";
    pinned = true;
  };
  qwen35-9b = {
    id = "qwen3.5:9b";
    hf = "Qwen/Qwen3.5-9B";
    ollama = "qwen3.5:9b";
    llama = "unsloth/Qwen3.5-9B-GGUF:Q4_K_M";
    pinned = true;
  };
  qwen38-27b = {
    id = "qwen3.8:27b";
    hf = "Qwen/Qwen3.8-27B";
    ollama = "qwen3.8:27b";
    llama = "unsloth/Qwen3.8-27B-GGUF:Q4_K_M";
  };
  qwen36-35b-a3b = {
    id = "qwen3.6:35b-a3b";
    hf = "Qwen/Qwen3.6-35B-A3B";
    ollama = "qwen3.6:35b-a3b";
    llama = "unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M";
    pinned = true;
  };
  gpt-oss-20b = {
    id = "gpt-oss:20b";
    hf = "openai/gpt-oss-20b";
    ollama = "gpt-oss:20b";
    # gpt-oss ships only its native MXFP4 quant; there is no Q4_K_M GGUF.
    llama = "ggml-org/gpt-oss-20b-GGUF:MXFP4";
    pinned = true;
  };
  ornith15-9b = {
    id = "ornith-1.5:9b";
    hf = "ornith-ai/Ornith-1.5-9B";
    ollama = "ornith-1.5:9b";
    llama = "ornith-ai/Ornith-1.5-9B-GGUF:Q4_K_M";
    pinned = true;
  };
  ornith15-35b-a3b = {
    id = "ornith-1.5:35b";
    hf = "ornith-ai/Ornith-1.5-35B-A3B";
    ollama = "ornith-1.5:35b";
    llama = "ornith-ai/Ornith-1.5-35B-A3B-GGUF:Q4_K_M";
    pinned = true;
  };
}
