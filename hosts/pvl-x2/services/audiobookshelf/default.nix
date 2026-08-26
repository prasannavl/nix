{
  config,
  stack,
  ...
}: let
  registry = stack.serviceRegistry;
  nginxPort = config.services.podman-compose.pvl.instances.nginx.exposedPorts.http.port;
  mediaDir = "/var/lib/pvl/media";
in {
  config.services.podman-compose.pvl.instances.audiobookshelf = rec {
    exposedPorts.http = {
      port = registry.portFor "audiobookshelf" "http";
      openFirewall = true;
      nginxHostNames = registry.domains.audiobookshelf;
      tunnels = [
        {
          kind = "cloudflare";
          hostNames = registry.domains.audiobookshelf;
          targetPort = nginxPort;
        }
      ];
      clientMaxBodySize = "250m";
      proxyReadTimeout = "3600s";
      proxySendTimeout = "3600s";
    };

    source = ''
      services:
        audiobookshelf:
          image: ghcr.io/advplyr/audiobookshelf:2.36.0
          container_name: audiobookshelf
          user: 0:0
          ports:
            - "${toString exposedPorts.http.port}:80"
          volumes:
            - ./config:/config
            - ./metadata:/metadata
            - ${mediaDir}/audiobooks:/audiobooks:ro
            - ${mediaDir}/podcasts:/podcasts:ro
    '';

    dirs = {
      "${mediaDir}/audiobooks".once = true;
      "${mediaDir}/podcasts".once = true;
      config.once = true;
      metadata.once = true;
    };
  };
}
