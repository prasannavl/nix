{config, ...}: let
  ai = config.services.ai;
  containerHost = "host.containers.internal";
  join = builtins.concatStringsSep ";";
  # `ports` follows each backend's deployment order, declared ROCm, NVIDIA,
  # CPU in services/ai.nix, so the CPU fallback is always last.
  ollamaBaseUrls =
    join (builtins.map (port: "http://${containerHost}:${toString port}") ai.backends.ollama.ports);
  llamaPorts = ai.backends.llamaRouter.runtimesInfo.default.ports;
  openaiBaseUrls =
    join (builtins.map (port: "http://${containerHost}:${toString port}/v1") llamaPorts);
  openaiApiKeys = join (builtins.map (_: "ollama") llamaPorts);
in {
  config.services.podman-compose.pvl.instances.openwebui = rec {
    exposedPorts.http = {
      port = 4000;
      openFirewall = true;
    };

    source = ''
      services:
        open-webui:
          image: ghcr.io/open-webui/open-webui:v0.10.2
          container_name: open-webui
          user: 0:0
          ports:
            - "${toString exposedPorts.http.port}:8080"
          environment:
            - OLLAMA_BASE_URLS=${ollamaBaseUrls}
            - OPENAI_API_BASE_URLS=${openaiBaseUrls}
            - OPENAI_API_KEYS=${openaiApiKeys}
          volumes:
            - ./open-webui_data:/app/backend/data
    '';
    # Ordering only: start after the main Ollama backend when it starts, but do
    # not fail or stop Open WebUI if that backend is down (Wants+After).
    wants = ["ollama-rocm"];
  };
}
