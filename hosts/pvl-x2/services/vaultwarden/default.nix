{config, ...}: let
  nginxPort = config.services.podman-compose.pvl.instances.nginx.exposedPorts.http.port;
in {
  config.services.podman-compose.pvl.instances.vaultwarden = rec {
    exposedPorts.http = {
      port = 2000;
      openFirewall = true;
      nginxHostNames = ["vaultwarden-x.p7log.com"];
      tunnels = [
        {
          kind = "cloudflare";
          hostNames = ["vaultwarden-x.p7log.com"];
          targetPort = nginxPort;
        }
      ];
      clientMaxBodySize = "100m";
    };

    source = ''
      services:
        vaultwarden:
          image: docker.io/vaultwarden/server:1.36.0
          container_name: vaultwarden
          environment:
            DOMAIN: "https://vault.p7log.com"
          user: 0:0
          volumes:
            - ./data:/data/
          ports:
            - "${toString exposedPorts.http.port}:80"
    '';
  };
}
