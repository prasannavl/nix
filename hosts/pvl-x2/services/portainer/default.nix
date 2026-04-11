{...}: {
  config.services.podmanCompose.pvl.instances.portainer = {podmanSocket, ...}: rec {
    exposedPorts = {
      http = {
        port = 8001;
        openFirewall = true;
      };
      https.port = 9444;
    };

    source = ./docker.compose.yaml;

    files.".env" = ''
      PORTAINER_HTTP_PORT=${toString exposedPorts.http.port}
      PORTAINER_HTTPS_PORT=${toString exposedPorts.https.port}
      PODMAN_SOCKET=${podmanSocket}
    '';
  };
}
