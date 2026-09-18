{config, ...}: let
  ai = config.services.ai;
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
            - OLLAMA_BASE_URL=http://127.0.0.1:${toString ai.backends.ollama.portsByName.ollama}
          volumes:
            - ./open-webui_data:/app/backend/data
    '';
    dependsOn = ["ollama"];
  };
}
