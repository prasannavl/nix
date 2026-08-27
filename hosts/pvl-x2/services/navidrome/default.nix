{
  config,
  stack,
  ...
}: let
  registry = stack.serviceRegistry;
  nginxPort = config.services.podman-compose.pvl.instances.nginx.exposedPorts.http.port;
  musicDir = "/var/lib/pvl/media/music";
in {
  config.services.podman-compose.pvl.instances.navidrome = rec {
    exposedPorts.http = {
      port = registry.portFor "navidrome" "http";
      openFirewall = true;
      useUpstreamCsp = true;
      nginxHostNames = registry.domains.navidrome;
      tunnels = [
        {
          kind = "cloudflare";
          hostNames = registry.domains.navidrome;
          targetPort = nginxPort;
        }
      ];
    };

    source = ''
      services:
        navidrome:
          image: ghcr.io/navidrome/navidrome:0.63.2
          container_name: navidrome
          user: 0:0
          ports:
            - "${toString exposedPorts.http.port}:4533"
          volumes:
            - ./data:/data
            - ${musicDir}:/music:ro
    '';

    dirs = {
      "${musicDir}".once = true;
      data.once = true;
    };
  };
}
