{
  config,
  stack,
  ...
}: let
  registry = stack.serviceRegistry;
  nginxPort = config.services.podman-compose.pvl.instances.nginx.exposedPorts.http.port;
  mediaDir = "/var/lib/pvl/media";
in {
  config.services.podman-compose.pvl.instances.jellyfin = rec {
    exposedPorts = {
      discovery = {
        port = registry.portFor "jellyfin" "discovery";
        protocols = ["udp"];
        openFirewall = true;
      };
      http = {
        port = registry.portFor "jellyfin" "http";
        openFirewall = true;
        nginxHostNames = registry.domains.jellyfin;
        tunnels = [
          {
            kind = "cloudflare";
            hostNames = registry.domains.jellyfin;
            targetPort = nginxPort;
          }
        ];
        clientMaxBodySize = "20m";
        proxyBuffering = false;
        proxyReadTimeout = "3600s";
        proxySendTimeout = "3600s";
      };
    };

    source = ''
      services:
        jellyfin:
          image: ghcr.io/jellyfin/jellyfin:10.11.11
          container_name: jellyfin
          user: 0:0
          group_add:
            - keep-groups
          devices:
            - /dev/dri:/dev/dri
          environment:
            JELLYFIN_PublishedServerUrl: "${registry.urlPublicFor "jellyfin"}"
          ports:
            - "${toString exposedPorts.http.port}:8096/tcp"
            - "${toString exposedPorts.discovery.port}:7359/udp"
          volumes:
            - ./config:/config
            - ./cache:/cache
            - ${mediaDir}:/media:ro
    '';

    dirs = {
      "${mediaDir}".once = true;
      cache.once = true;
      config.once = true;
    };
  };
}
