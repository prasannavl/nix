{pkgs}: {
  # The null-provider package skips the patched suite. Use a neutral binding so
  # this check always exercises saved-choice protection during the app build.
  managed-byok-provider = pkgs.callPackage ../default.nix {
    managedByokProvider = {
      id = "test-provider";
      title = "Test Provider";
      label = "Test Provider (Ollama)";
      protocol = "ollama";
      baseUrl = "http://127.0.0.1:11434";
      model = "synthetic-chat";
      apiKey = "synthetic-managed-only";
      requiresApiKey = false;
    };
  };
}
