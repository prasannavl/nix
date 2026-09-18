{pkgs}: let
  lib = pkgs.lib;
  aiLib = import ../default.nix {inherit lib;};
  catalog = aiLib.catalog;

  allKeys = builtins.attrNames catalog;

  # builtins.attrNames returns sorted order; the assertion pins that
  # semantic because reconciler order derives from it for full-catalog hosts.
  expectedKeys = [
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
in
  assert allKeys == expectedKeys;
  assert builtins.all (
    key: let
      entry = catalog.${key};
    in
      (entry ? id) && (entry ? hf) && (entry ? ollama) && (entry ? llama)
  )
  allKeys;
  assert aiLib.missingKeys hostSelection == [];
  assert aiLib.missingKeys (hostSelection ++ ["gemma99-typo" "nomic-embed-text"]) == ["gemma99-typo"];
  assert aiLib.missingRefs "ollama" hostEntries == [];
  assert aiLib.missingRefs "llama" hostEntries == [];
  assert aiLib.missingRefs "nonexistent" hostEntries == hostEntries;
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
  };
  assert presetsWithoutEmbedding."nomic-ai/nomic-embed-text-v1.5-GGUF:Q4_K_M" == {alias = "nomic-embed-text";};
  assert presetsWithEmbedding."unsloth/gemma-4-E2B-it-GGUF:Q4_K_M" == {alias = "gemma4:e2b";};
  assert builtins.length (builtins.attrNames presetsWithEmbedding) == builtins.length hostEntries;
  assert builtins.length (builtins.attrNames presetsWithoutEmbedding) == builtins.length hostEntries;
    pkgs.runCommand "ai-lib-test" {} ''
      touch $out
    ''
