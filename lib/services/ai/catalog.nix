{
  # The fleet-wide AI model catalog. Keys are stable attr names used by host
  # selections (services.ai.models); each entry carries the model's
  # client-facing id plus per-backend references:
  #   id     - the shared, client-facing model id (Ollama tag and llama alias)
  # Backend fields accept either a reference string or an expanded attrset
  # whose `ref` carries that string and whose remaining fields configure the
  # backend:
  #   hf     - the upstream Hugging Face safetensors repo (vLLM/SGLang)
  #   ollama - the Ollama tag served by Ollama backends
  #   llama  - the GGUF reference plus optional llama.cpp router preset
  #            (llama.runtimes lists compatible engines: the default upstream
  #            build `default`, or named forks such as `prism`)
  #   pinned - surfaced as a default-pinned model by Web UI consumers
  # Catalog keys follow <model-name>-<target-size>[-<encoding>][-<variant>].
  # Encoding is omitted when one logical entry intentionally maps to different
  # native artifacts across backends. GGUF conversions live in separate repos
  # under different orgs (unsloth, ornith-ai, nomic-ai, ggml-org), so the
  # mapping is declared, not derived. Keep families alphabetical, base models
  # in natural size order, and each base model's variants directly after it.
  bonsai2-27b = {
    id = "bonsai2:27b";
    # Ternary-weight model that only the PrismML llama.cpp fork loads, so it
    # is pinned to the `prism` runtime. Only its public GGUF distribution is
    # declared; there is no public base safetensors repository.
    llama = {
      ref = "prism-ml/Ternary-Bonsai-2-27B-gguf:PTQ1_0";
      runtimes = ["prism"];
      preset.jinja = "true";
    };
  };

  # Reserved for later activation; intentionally omitted from the active
  # catalog while this exceptionally large model is not deployed.
  /*
  deepseek-v41-flash-763b-fp8 = {
    id = "deepseek-v4.1:flash";
    hf = "deepseek-ai/DeepSeek-V4.1-Flash";
  };
  */

  gemma4-e2b = {
    id = "gemma4:e2b";
    hf = "google/gemma-4-E2B-it";
    ollama = "gemma4:e2b";
    llama = {
      ref = "unsloth/gemma-4-E2B-it-GGUF:Q4_K_M";
      preset.jinja = "true";
    };
    pinned = true;
  };
  gemma4-e4b = {
    id = "gemma4:e4b";
    hf = "google/gemma-4-E4B-it";
    ollama = "gemma4:e4b";
    llama = {
      ref = "unsloth/gemma-4-E4B-it-GGUF:Q4_K_M";
      preset.jinja = "true";
    };
    pinned = true;
  };
  gemma4-12b = {
    id = "gemma4:12b";
    hf = "google/gemma-4-12B-it";
    ollama = "gemma4:12b";
    llama = {
      ref = "unsloth/gemma-4-12b-it-GGUF:Q4_K_M";
      preset.jinja = "true";
    };
    pinned = true;
    artifacts = {
      bf16-dflash.hf = "deepseek-ai/dflash_gemma4_12b_block7";
      bf16-dspark.hf = "deepseek-ai/dspark_gemma4_12b_block7";
      bf16-eagle3.hf = "deepseek-ai/eagle3_gemma4_12b_ttt7";
    };
  };
  gemma4-26b-a4b = {
    id = "gemma4:26b";
    hf = "google/gemma-4-26B-A4B-it";
    ollama = "gemma4:26b";
    llama = {
      ref = "unsloth/gemma-4-26B-A4B-it-GGUF:Q4_K_M";
      preset.jinja = "true";
    };
    pinned = true;
  };
  gemma4-31b = {
    id = "gemma4:31b";
    hf = "google/gemma-4-31B-it";
    ollama = "gemma4:31b";
    llama = {
      ref = "unsloth/gemma-4-31B-it-GGUF:Q4_K_M";
      preset.jinja = "true";
    };
  };

  gpt-oss-20b-mxfp4 = {
    id = "gpt-oss:20b";
    hf = "openai/gpt-oss-20b";
    ollama = "gpt-oss:20b";
    # gpt-oss ships only its native MXFP4 quant; there is no Q4_K_M GGUF.
    llama = {
      ref = "ggml-org/gpt-oss-20b-GGUF:MXFP4";
      preset.jinja = "true";
    };
    pinned = true;
  };

  nomic-embed-text-v15-100m = {
    id = "nomic-embed-text";
    hf = "nomic-ai/nomic-embed-text-v1.5";
    ollama = "nomic-embed-text";
    llama = "nomic-ai/nomic-embed-text-v1.5-GGUF:Q4_K_M";
  };

  ornith15-9b = {
    id = "ornith-1.5:9b";
    hf = "ornith-ai/Ornith-1.5-9B";
    ollama = "ornith-1.5:9b";
    llama = {
      ref = "ornith-ai/Ornith-1.5-9B-GGUF:Q4_K_M";
      preset.jinja = "true";
    };
    pinned = true;
  };
  ornith15-35b-a3b = {
    id = "ornith-1.5:35b";
    hf = "ornith-ai/Ornith-1.5-35B-A3B";
    ollama = "ornith-1.5:35b";
    llama = {
      ref = "ornith-ai/Ornith-1.5-35B-A3B-GGUF:Q4_K_M";
      preset.jinja = "true";
    };
    pinned = true;
  };

  qwen35-800m = {
    id = "qwen3.5:0.8b";
    hf = "Qwen/Qwen3.5-0.8B";
    ollama = "qwen3.5:0.8b";
    llama = {
      ref = "unsloth/Qwen3.5-0.8B-GGUF:Q4_K_M";
      preset.jinja = "true";
    };
    pinned = true;
  };
  qwen35-2b = {
    id = "qwen3.5:2b";
    hf = "Qwen/Qwen3.5-2B";
    ollama = "qwen3.5:2b";
    llama = {
      ref = "unsloth/Qwen3.5-2B-GGUF:Q4_K_M";
      preset.jinja = "true";
    };
    pinned = true;
  };
  qwen35-4b = {
    id = "qwen3.5:4b";
    hf = "Qwen/Qwen3.5-4B";
    ollama = "qwen3.5:4b";
    llama = {
      ref = "unsloth/Qwen3.5-4B-GGUF:Q4_K_M";
      preset.jinja = "true";
    };
    pinned = true;
  };
  qwen35-9b = {
    id = "qwen3.5:9b";
    hf = "Qwen/Qwen3.5-9B";
    ollama = "qwen3.5:9b";
    llama = {
      ref = "unsloth/Qwen3.5-9B-GGUF:Q4_K_M";
      preset.jinja = "true";
    };
    pinned = true;
  };
  qwen38-27b = {
    id = "qwen3.8:27b";
    hf = "Qwen/Qwen3.8-27B";
    ollama = "qwen3.8:27b";
    llama = {
      ref = "unsloth/Qwen3.8-27B-GGUF:Q4_K_M";
      preset.jinja = "true";
    };
    artifacts = {
      f16-mmproj.hf = {
        ref = "unsloth/Qwen3.8-27B-GGUF";
        include = ["mmproj-F16.gguf"];
      };
      q4-mtp.hf = {
        ref = "unsloth/Qwen3.8-27B-GGUF";
        include = ["MTP/mtp-Qwen3.8-27B-Q4_0.gguf"];
      };
    };
  };
  qwen38-27b-fp8 = {
    id = "qwen3.8:27b-fp8";
    hf = "Qwen/Qwen3.8-27B-FP8";
  };
  # Reserved for later activation; keep both native and GGUF sources together
  # while this exceptionally large model family is outside the active catalog.
  /*
  qwen38-flash-next-125b-a6b = {
    id = "qwen3.8:flash-next";
    hf = "Qwen/Qwen3.8-Flash-Next";
    llama = {
      ref = "unsloth/Qwen3.8-Flash-Next-GGUF:UD-Q4_K_XL";
      preset.jinja = "true";
    };
    artifacts = {
      f16-mmproj.hf = {
        ref = "unsloth/Qwen3.8-Flash-Next-GGUF";
        include = ["mmproj-F16.gguf"];
      };
      q4-km-mtp.hf = {
        ref = "unsloth/Qwen3.8-Flash-Next-GGUF";
        include = ["MTP/mtp-Qwen3.8-Flash-Next-Q4_K_M.gguf"];
      };
    };
  };
  qwen38-flash-next-125b-a6b-fp8 = {
    id = "qwen3.8:flash-next-fp8";
    hf = "Qwen/Qwen3.8-Flash-Next-FP8";
  };
  */
}
