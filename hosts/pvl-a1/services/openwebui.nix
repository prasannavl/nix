{config, ...}: let
  ai = config.services.ai;
  ollamaBaseUrls =
    builtins.concatStringsSep
    ";"
    (builtins.map (port: "http://host.containers.internal:${toString port}") ai.backends.ollama.ports);
in {
  services.podman-compose.pvl.instances.openwebui = rec {
    exposedPorts.http = {
      port = 4000;
    };

    source = ''
      services:
        open-webui:
          image: ghcr.io/open-webui/open-webui:v0.10.2
          container_name: open-webui
          ports:
            - "${toString exposedPorts.http.port}:8080"
          environment:
            - OLLAMA_BASE_URLS=${ollamaBaseUrls}
          volumes:
            - ./open-webui_data:/app/backend/data
    '';
  };
}
