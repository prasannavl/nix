{pkgs}: let
  backendLib = import ../backends.nix;
  prefetchLib = import ../prefetch.nix;
  catalog = import ../catalog.nix;
  storagePathContract = builtins.fromJSON (builtins.readFile ./fixtures/storage-path-contract.json);
  allKeys = builtins.attrNames catalog;
  expectedKeys = [
    "bonsai2-27b"
    "gemma4-12b"
    "gemma4-26b-a4b"
    "gemma4-31b"
    "gemma4-e2b"
    "gemma4-e4b"
    "gpt-oss-20b-mxfp4"
    "nomic-embed-text-v15-100m"
    "ornith15-35b-a3b"
    "ornith15-9b"
    "qwen35-2b"
    "qwen35-4b"
    "qwen35-800m"
    "qwen35-9b"
    "qwen38-27b"
    "qwen38-27b-fp8"
  ];
  chatKeys = builtins.filter (key: key != "nomic-embed-text-v15-100m" && catalog.${key} ? llama) allKeys;
  resolvedPrefetch = prefetchLib.resolveHf {
    inherit catalog;
    selections = {
      gemma4-12b = ["bf16-eagle3"];
      qwen38-27b = {
        base = false;
        artifacts = ["q4-mtp"];
      };
      qwen38-27b-fp8 = false;
    };
  };
  emptyResolvedPrefetch = prefetchLib.resolveHf {
    inherit catalog;
    selections.gemma4-12b = {
      base = false;
      artifacts = false;
    };
  };
in
  assert allKeys == expectedKeys;
  assert builtins.all (key: catalog.${key} ? id) allKeys;
  assert backendLib.missingKeysFrom catalog ["gemma4-e2b" "missing"] == ["missing"];
  assert backendLib.llamaRuntimes catalog.bonsai2-27b == ["prism"];
  assert backendLib.llamaRuntimes catalog.gemma4-e2b == ["default"];
  assert backendLib.llamaRuntimes {
    id = "ollama-only";
    ollama = "ollama-only:1";
  }
  == [];
  assert backendLib.llamaRuntimes {
    id = "multi-runtime";
    llama = {
      ref = "example/multi-runtime";
      runtimes = ["default" "prism"];
    };
  }
  == ["default" "prism"];
  assert backendLib.validLlamaRuntimes {
    id = "multi-runtime";
    llama = {
      ref = "example/multi-runtime";
      runtimes = ["default" "prism"];
    };
  };
  assert !(backendLib.validLlamaRuntimes {
    id = "duplicate-runtime";
    llama = {
      ref = "example/duplicate-runtime";
      runtimes = ["default" "default"];
    };
  });
  assert backendLib.validRuntimeName "default";
  assert backendLib.validRuntimeName "prism-2";
  assert !(backendLib.validRuntimeName "Prism");
  assert !(backendLib.validRuntimeName "../prism");
  assert !(backendLib.validRuntimeName "prism runtime");
  assert backendLib.effectiveDeploymentValue {runtime = "default";} {runtime = "prism";} "runtime" "fallback" == "prism";
  assert backendLib.effectiveDeploymentValue {runtime = "default";} {} "runtime" "fallback" == "default";
  assert backendLib.effectiveDeploymentValue {} {} "runtime" "fallback" == "fallback";
  assert builtins.all backendLib.validStoragePath storagePathContract.valid;
  assert backendLib.storagePathContains "/var/lib/example" "/var/lib/example/models";
  assert backendLib.storagePathsOverlap "/var/lib/example" "/var/lib/example/models";
  assert backendLib.storagePathsOverlap "/var/lib/example/models" "/var/lib/example/models";
  assert !(backendLib.storagePathsOverlap "/var/lib/example" "/var/lib/examples");
  assert !(backendLib.storagePathsOverlap "/var/lib/example-a" "/var/lib/example-b");
  assert backendLib.indexedPairs ["a" "b" "c"]
  == [
    {
      left = "a";
      right = "b";
    }
    {
      left = "a";
      right = "c";
    }
    {
      left = "b";
      right = "c";
    }
  ];
  assert builtins.all (path: !backendLib.validStoragePath path) storagePathContract.invalid;
  assert backendLib.validHfConfig {
    ref = "example/model";
    revision = "release";
    include = ["weights/model.safetensors"];
  };
  assert !(backendLib.validHfConfig {
    ref = "";
    include = ["weights/model.safetensors"];
  });
  assert builtins.all (key: catalog.${key}.llama.preset.jinja == "true") chatKeys;
  assert builtins.isString catalog.nomic-embed-text-v15-100m.llama;
  assert backendLib.backendConfig "ollama" catalog.gemma4-e2b == {ref = "gemma4:e2b";};
  assert builtins.attrNames (backendLib.artifactsOf catalog.gemma4-12b)
  == [
    "bf16-dflash"
    "bf16-dspark"
    "bf16-eagle3"
  ];
  assert backendLib.artifactConfig "hf" catalog.qwen38-27b "q4-mtp"
  == {
    ref = "unsloth/Qwen3.8-27B-GGUF";
    include = ["MTP/mtp-Qwen3.8-27B-Q4_0.gguf"];
  };
  assert backendLib.backendConfig "ollama" "invalid-entry" == null;
  assert !(catalog.bonsai2-27b ? hf);
  assert builtins.map (unit: unit.id) resolvedPrefetch.units
  == [
    "hf:gemma4-12b"
    "hf:gemma4-12b:bf16-eagle3"
    "hf:qwen38-27b:q4-mtp"
  ];
  assert resolvedPrefetch.unknownModels == [];
  assert resolvedPrefetch.unknownArtifacts == [];
  assert resolvedPrefetch.duplicateArtifacts == [];
  assert emptyResolvedPrefetch.emptyModels == ["gemma4-12b"];
  assert backendLib.backendConfig "llama" catalog.gemma4-e2b
  == {
    ref = "unsloth/gemma-4-E2B-it-GGUF:Q4_K_M";
    preset.jinja = "true";
  };
    pkgs.runCommand "ai-lib-test" {} ''
      touch $out
    ''
