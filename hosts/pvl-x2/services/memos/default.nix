{config, ...}: let
  nginxPort = config.services.podman-compose.pvl.instances.nginx.exposedPorts.http.port;
in {
  config.services.podman-compose.pvl.instances.memos = rec {
    exposedPorts.http = {
      port = 5230;
      openFirewall = true;
      nginxHostNames = ["memos-x.p7log.com"];
      tunnels = [
        {
          kind = "cloudflare";
          hostNames = ["memos-x.p7log.com"];
          targetPort = nginxPort;
        }
      ];
      clientMaxBodySize = "100m";
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
