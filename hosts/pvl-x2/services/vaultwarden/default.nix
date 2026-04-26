{config, ...}: let
  nginxPort = config.services.podmanCompose.pvl.instances.nginx.exposedPorts.http.port;
in {
  config.services.podmanCompose.pvl.instances.vaultwarden = rec {
    exposedPorts.http = {
      port = 2000;
      openFirewall = true;
      nginxHostNames = ["vaultwarden-x.p7log.com"];
      cfTunnelNames = ["vaultwarden-x.p7log.com"];
      cfTunnelPort = nginxPort;
    };

    source = ''
      services:
        vaultwarden:
          image: docker.io/vaultwarden/server:latest
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
