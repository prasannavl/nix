{config, ...}: let
  ai = config.services.ai;
  join = builtins.concatStringsSep ";";
  # Ordered ROCm, CPU endpoint lists from the shared AI projection.
  consumers = ai.consumersFor "host.containers.internal";
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
            - OLLAMA_BASE_URLS=${join consumers.ollama.urls}
            - OPENAI_API_BASE_URLS=${join consumers.llama.openaiUrls}
            - OPENAI_API_KEYS=${join consumers.llama.apiKeys}
          volumes:
            - ./open-webui_data:/app/backend/data
    '';
    # Ordering only: start after the main Ollama backend when it starts, but do
    # not fail or stop Open WebUI if that backend is down (Wants+After).
    wants = ["ollama-rocm"];
  };
}
