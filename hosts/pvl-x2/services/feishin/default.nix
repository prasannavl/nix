{
  config,
  stack,
  ...
}: let
  registry = stack.serviceRegistry;
  nginxPort = config.services.podman-compose.pvl.instances.nginx.exposedPorts.http.port;
in {
  config.services.podman-compose.pvl.instances.feishin = rec {
    exposedPorts.http = {
      port = registry.portFor "feishin" "http";
      openFirewall = true;
      useUpstreamCsp = true;
      nginxHostNames = registry.domains.feishin;
      tunnels = [
        {
          kind = "cloudflare";
          hostNames = registry.domains.feishin;
          targetPort = nginxPort;
        }
      ];
    };

    source = ''
      services:
        feishin:
          image: ghcr.io/jeffvli/feishin:1.15.1
          container_name: feishin
          environment:
            ANALYTICS_DISABLED: "true"
            SERVER_LOCK: "true"
            SERVER_NAME: Navidrome
            SERVER_TYPE: navidrome
            SERVER_URL: "${registry.urlPublicFor "navidrome"}"
          ports:
            - "${toString exposedPorts.http.port}:9180"
    '';

    dependsOn = ["navidrome"];
  };
}
