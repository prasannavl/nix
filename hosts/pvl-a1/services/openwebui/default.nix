{config, ...}: let
  ollamaPort = config.services.podmanCompose.pvl.instances.ollama.exposedPorts.main.port;
in {
  config.services.podmanCompose.pvl.instances.openwebui = rec {
    exposedPorts.http = {
      port = 4000;
    };

    source = ./docker.compose.yaml;
    dependsOn = ["ollama"];

    files.".env".text = ''
      OPEN_WEBUI_PORT=${toString exposedPorts.http.port}
      OLLAMA_BASE_URL="http://host.containers.internal:${toString ollamaPort}"
    '';
  };
}
