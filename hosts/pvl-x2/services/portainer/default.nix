{...}: {
  config.services.podman-compose.pvl.instances.portainer = {podmanSocket, ...}: rec {
    exposedPorts = {
      http = {
        port = 8001;
        openFirewall = true;
      };
      https.port = 9444;
    };

    source = ''
      version: "3.8"

      services:
        portainer:
          image: docker.io/portainer/portainer-ce:2.39.4
          container_name: portainer
          ports:
            - "${toString exposedPorts.http.port}:8000"
            - "${toString exposedPorts.https.port}:9443"
          privileged: true
          volumes:
            - type: bind
              source: ${podmanSocket}
              target: /var/run/docker.sock
            - ./data:/data
    '';
  };
}
