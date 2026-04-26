{config, ...}: let
  ollamaPort = config.services.podmanCompose.pvl.instances.ollama.exposedPorts.main.port;
in {
  config.services.podmanCompose.pvl.instances.openwebui = rec {
    exposedPorts.http = {
      port = 4000;
    };

    source = ''
      services:
        open-webui:
          image: ghcr.io/open-webui/open-webui:main
          container_name: open-webui
          ports:
            - "${toString exposedPorts.http.port}:8080"
          environment:
            - OLLAMA_BASE_URL=http://host.containers.internal:${toString ollamaPort}
          volumes:
            - ./open-webui_data:/app/backend/data
    '';
    dependsOn = ["ollama"];
  };
}
