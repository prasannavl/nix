{...}: {
  config.services.podmanCompose.pvl.instances.ollama = rec {
    exposedPorts.main = {
      port = 11434;
      openFirewall = true;
    };

    source = ./docker.compose.yaml;

    files.".env" = ''
      OLLAMA_API_PORT=${toString exposedPorts.main.port}
    '';
  };
}
