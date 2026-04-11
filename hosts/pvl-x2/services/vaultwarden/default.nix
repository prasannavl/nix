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

    source = ./docker.compose.yaml;

    files.".env" = ''
      VAULTWARDEN_HTTP_PORT=${toString exposedPorts.http.port}
    '';
  };
}
