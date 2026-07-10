{config, ...}: let
  ollamaPort = config.services.podman-compose.pvl.instances.ollama.exposedPorts.main.port;
  ollamaNvidiaPort = config.services.podman-compose.pvl.instances.ollama-nvidia.exposedPorts.main.port;
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
            - OLLAMA_BASE_URLS=http://host.containers.internal:${toString ollamaPort};http://host.containers.internal:${toString ollamaNvidiaPort}
          volumes:
            - ./open-webui_data:/app/backend/data
    '';
  };
}
