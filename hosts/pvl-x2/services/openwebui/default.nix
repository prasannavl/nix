{config, ...}: let
  ollamaPort = config.services.podmanCompose.pvl.instances.ollama.exposedPorts.main.port;
in {
  config.services.podmanCompose.pvl.instances.openwebui = rec {
    exposedPorts.http = {
      port = 4000;
      openFirewall = true;
    };

    source = ./docker.compose.yaml;
    dependsOn = ["ollama"];

    files.".env" = ''
      OLLAMA_API_PORT=${toString ollamaPort}
      OPEN_WEBUI_PORT=${toString exposedPorts.http.port}
    '';
  };
}
