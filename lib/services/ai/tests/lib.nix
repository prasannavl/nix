{pkgs}: let
  lib = pkgs.lib;
  aiLib = import ../default.nix {inherit lib;};
  catalog = aiLib.catalog;

  allKeys = builtins.attrNames catalog;

  # builtins.attrNames returns sorted order; the assertion pins that
  # semantic because reconciler order derives from it for full-catalog hosts.
  expectedKeys = [
    "bonsai-2-27b"
    "gemma4-12b"
    "gemma4-26b"
    "gemma4-31b"
    "gemma4-e2b"
    "gemma4-e4b"
    "gpt-oss-20b"
    "nomic-embed-text"
    "ornith15-35b-a3b"
    "ornith15-9b"
    "qwen35-08b"
    "qwen35-2b"
    "qwen35-4b"
    "qwen35-9b"
    "qwen36-35b-a3b"
    "qwen38-27b"
  ];

  # A host-style selection: subset, preserved order.
  hostSelection = [
    "nomic-embed-text"
    "gemma4-e2b"
    "gemma4-e4b"
    "qwen35-08b"
    "qwen35-2b"
    "qwen35-4b"
    "qwen35-9b"
  ];
  hostEntries = builtins.map (key: catalog.${key}) hostSelection;

  presetsWithEmbedding = aiLib.llamaPresets "nomic-embed-text" hostEntries;
  presetsWithoutEmbedding = aiLib.llamaPresets null hostEntries;
  chatKeys = builtins.filter (key: key != "nomic-embed-text") allKeys;
  protectedOverride = builtins.tryEval (builtins.deepSeq (aiLib.llamaPresets null [
      {
        id = "invalid";
        llama = {
          ref = "example/invalid:Q4_K_M";
          preset.alias = "override";
        };
      }
    ])
    true);
  duplicateRef = builtins.tryEval (builtins.deepSeq (aiLib.llamaPresets null [
      {
        id = "first";
        llama = "example/shared:Q4";
      }
      {
        id = "second";
        llama = "example/shared:Q4";
      }
    ])
    true);
  duplicateAlias = builtins.tryEval (builtins.deepSeq (aiLib.llamaPresets null [
      {
        id = "duplicate";
        llama = "example/first:Q4";
      }
      {
        id = "duplicate";
        llama = "example/second:Q4";
      }
    ])
    true);
in
  assert allKeys == expectedKeys;
  assert builtins.all (
    key: let
      entry = catalog.${key};
    in
      entry ? id
  )
  allKeys;
  assert aiLib.missingKeys hostSelection == [];
  assert aiLib.missingKeysFrom {backend-only = {id = "backend-only";};} ["backend-only"] == [];
  assert aiLib.missingKeys (hostSelection ++ ["gemma99-typo" "nomic-embed-text"]) == ["gemma99-typo"];
  assert aiLib.missingRefs "ollama" hostEntries == [];
  assert aiLib.missingRefs "llama" hostEntries == [];
  assert aiLib.missingRefs "nonexistent" hostEntries == hostEntries;
  assert aiLib.llamaRuntime catalog.bonsai-2-27b == "prism";
  assert aiLib.llamaRuntime catalog.gemma4-e2b == "default";
  assert aiLib.llamaRuntime {
    id = "inline";
    llama = "example/inline-GGUF:Q4_K_M";
  }
  == "default";
  assert aiLib.llamaRuntime {
    id = "ollama-only";
    ollama = "ollama-only:1";
  }
  == null;
  assert aiLib.llamaRuntime {
    id = "invalid-runtime";
    llama = {
      ref = "example/invalid-runtime";
      runtime = 1;
    };
  }
  == null;
  assert aiLib.configuredBackends {
    entry = {
      id = "both";
      llama = "example/both";
      ollama = "both:1";
    };
    ollama = true;
    runtimes.default.deployments = [{}];
  }
  == {
    llamaRuntime = "default";
    ollama = true;
  };
  assert aiLib.configuredBackends {
    entry = {
      id = "not-deployed";
      llama = "example/not-deployed";
    };
    runtimes.default = {};
  }
  == {
    llamaRuntime = null;
    ollama = false;
  };
  assert builtins.all (key: catalog.${key}.llama.preset.jinja == "true") chatKeys;
  assert builtins.isString catalog.nomic-embed-text.llama;
  assert aiLib.backendConfig "ollama" catalog.gemma4-e2b == {ref = "gemma4:e2b";};
  assert aiLib.backendConfig "ollama" "invalid-entry" == null;
  assert aiLib.backendConfig "llama" catalog.gemma4-e2b
  == {
    ref = "unsloth/gemma-4-E2B-it-GGUF:Q4_K_M";
    preset.jinja = "true";
  };
  assert aiLib.missingRefs "llama" [
    {
      id = "ollama-only";
      ollama = "ollama-only:1";
    }
  ]
  != [];
  assert aiLib.missingRefs "llama" [
    {
      id = "invalid-llama";
      llama.preset.jinja = "true";
    }
  ]
  != [];
  assert aiLib.projectModels "ollama" hostEntries
  == [
    "nomic-embed-text"
    "gemma4:e2b"
    "gemma4:e4b"
    "qwen3.5:0.8b"
    "qwen3.5:2b"
    "qwen3.5:4b"
    "qwen3.5:9b"
  ];
  assert aiLib.projectModels "llama" hostEntries
  == [
    "nomic-ai/nomic-embed-text-v1.5-GGUF:Q4_K_M"
    "unsloth/gemma-4-E2B-it-GGUF:Q4_K_M"
    "unsloth/gemma-4-E4B-it-GGUF:Q4_K_M"
    "unsloth/Qwen3.5-0.8B-GGUF:Q4_K_M"
    "unsloth/Qwen3.5-2B-GGUF:Q4_K_M"
    "unsloth/Qwen3.5-4B-GGUF:Q4_K_M"
    "unsloth/Qwen3.5-9B-GGUF:Q4_K_M"
  ];
  # Every backend reference is distinct within a selection.
  assert lib.unique (aiLib.projectModels "ollama" hostEntries) == aiLib.projectModels "ollama" hostEntries;
  # Embedding flag lands on exactly the embedding model, and only when set.
  assert presetsWithEmbedding."nomic-ai/nomic-embed-text-v1.5-GGUF:Q4_K_M"
  == {
    alias = "nomic-embed-text";
    embeddings = "true";
    poll = "0";
  };
  assert presetsWithoutEmbedding."nomic-ai/nomic-embed-text-v1.5-GGUF:Q4_K_M"
  == {
    alias = "nomic-embed-text";
    poll = "0";
  };
  assert presetsWithEmbedding."unsloth/gemma-4-E2B-it-GGUF:Q4_K_M"
  == {
    alias = "gemma4:e2b";
    jinja = "true";
    poll = "0";
  };
  assert !protectedOverride.success;
  assert !duplicateRef.success;
  assert !duplicateAlias.success;
  assert builtins.length (builtins.attrNames presetsWithEmbedding) == builtins.length hostEntries;
  assert builtins.length (builtins.attrNames presetsWithoutEmbedding) == builtins.length hostEntries;
    pkgs.runCommand "ai-lib-test" {} ''
      touch $out
    ''
