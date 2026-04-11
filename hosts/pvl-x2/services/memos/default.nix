{config, ...}: let
  nginxPort = config.services.podmanCompose.pvl.instances.nginx.exposedPorts.http.port;
in {
  config.services.podmanCompose.pvl.instances.memos = rec {
    exposedPorts.http = {
      port = 5230;
      openFirewall = true;
      nginxHostNames = ["memos-x.p7log.com"];
      cfTunnelNames = ["memos-x.p7log.com"];
      cfTunnelPort = nginxPort;
    };

    source = ./docker.compose.yaml;

    files.".env" = ''
      MEMOS_HTTP_PORT=${toString exposedPorts.http.port}
    '';
  };
}
