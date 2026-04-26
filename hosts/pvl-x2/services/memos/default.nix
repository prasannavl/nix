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

    source = ''
      services:
        memos:
          image: docker.io/neosmemo/memos:stable
          container_name: memos
          user: 0:0
          volumes:
            - ./data:/var/opt/memos
          ports:
            - "${toString exposedPorts.http.port}:5230"
    '';
  };
}
