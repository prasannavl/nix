{pkgs}: let
  backendLib = import ../backends.nix;
  catalog = import ../catalog.nix;
  allKeys = builtins.attrNames catalog;
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
  chatKeys = builtins.filter (key: key != "nomic-embed-text") allKeys;
in
  assert allKeys == expectedKeys;
  assert builtins.all (key: catalog.${key} ? id) allKeys;
  assert backendLib.missingKeysFrom catalog ["gemma4-e2b" "missing"] == ["missing"];
  assert backendLib.llamaRuntime catalog.bonsai-2-27b == "prism";
  assert backendLib.llamaRuntime catalog.gemma4-e2b == "default";
  assert backendLib.llamaRuntime {
    id = "ollama-only";
    ollama = "ollama-only:1";
  }
  == null;
  assert backendLib.configuredBackends {
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
  assert backendLib.configuredBackends {
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
  assert backendLib.backendConfig "ollama" catalog.gemma4-e2b == {ref = "gemma4:e2b";};
  assert backendLib.backendConfig "ollama" "invalid-entry" == null;
  assert backendLib.backendConfig "llama" catalog.gemma4-e2b
  == {
    ref = "unsloth/gemma-4-E2B-it-GGUF:Q4_K_M";
    preset.jinja = "true";
  };
    pkgs.runCommand "ai-lib-test" {} ''
      touch $out
    ''
