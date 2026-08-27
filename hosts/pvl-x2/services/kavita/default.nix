{
  config,
  lib,
  stack,
  ...
}: let
  registry = stack.serviceRegistry;
  nginxLib = import ../../../../lib/services/nginx {inherit lib;};
  nginxPort = config.services.podman-compose.pvl.instances.nginx.exposedPorts.http.port;
  mediaDir = "/var/lib/pvl/media";
in {
  config.services.podman-compose.pvl.instances.kavita = rec {
    exposedPorts.http = {
      port = registry.portFor "kavita" "http";
      openFirewall = true;
      rateLimit = nginxLib.rateLimitProfiles.web;
      useUpstreamCsp = true;
      nginxHostNames = registry.domains.kavita;
      tunnels = [
        {
          kind = "cloudflare";
          hostNames = registry.domains.kavita;
          targetPort = nginxPort;
        }
      ];
      clientMaxBodySize = "250m";
    };

    source = ''
      services:
        kavita:
          image: ghcr.io/kareadita/kavita:0.9.0.2
          container_name: kavita
          user: 0:0
          ports:
            - "${toString exposedPorts.http.port}:5000"
          volumes:
            - ./config:/kavita/config
            - ${mediaDir}/books:/books:ro
            - ${mediaDir}/documents:/documents:ro
    '';

    dirs = {
      "${mediaDir}/books".once = true;
      "${mediaDir}/documents".once = true;
      config.once = true;
    };
  };
}
