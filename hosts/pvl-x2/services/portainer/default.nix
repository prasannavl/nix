{...}: {
  config.services.podman-compose.pvl.instances.portainer = {podmanSocket, ...}: rec {
    exposedPorts = {
      edge = {
        port = 8001;
        openFirewall = true;
      };
      http = {
        port = 9444;
        upstreamProtocol = "https";
      };
    };

    source = ''
      version: "3.8"

      services:
        portainer:
          image: docker.io/portainer/portainer-ce:2.43.0
          container_name: portainer
          ports:
            - "${toString exposedPorts.edge.port}:8000"
            - "${toString exposedPorts.http.port}:9443"
          privileged: true
          volumes:
            - type: bind
              source: ${podmanSocket}
              target: /var/run/docker.sock
            - ./data:/data
    '';
  };
}
