{
  config,
  stack,
  ...
}: let
  registry = stack.serviceRegistry;
  nginxPort = config.services.podman-compose.pvl.instances.nginx.exposedPorts.http.port;
  composeSecretUser = "pvl";
in {
  config = {
    services.podman-compose.pvl.instances.paperless = rec {
      exposedPorts.http = {
        port = registry.portFor "paperless" "http";
        openFirewall = true;
        useUpstreamCsp = true;
        nginxHostNames = registry.domains.paperless;
        tunnels = [
          {
            kind = "cloudflare";
            hostNames = registry.domains.paperless;
            targetPort = nginxPort;
          }
        ];
        clientMaxBodySize = "250m";
        proxyReadTimeout = "3600s";
        proxySendTimeout = "3600s";
      };

      source = ''
        services:
          broker:
            image: docker.io/valkey/valkey:9.0.2-alpine
            container_name: paperless-broker
            user: 0:0
            volumes:
              - ./broker:/data

          webserver:
            image: ghcr.io/paperless-ngx/paperless-ngx:3.0.5
            container_name: paperless-webserver
            user: 0:0
            depends_on:
              - broker
            environment:
              PAPERLESS_DBENGINE: sqlite
              PAPERLESS_REDIS: redis://broker:6379
              PAPERLESS_URL: "${registry.urlPublicFor "paperless"}"
            ports:
              - "${toString exposedPorts.http.port}:8000"
            volumes:
              - ./data:/usr/src/paperless/data
              - ./media:/usr/src/paperless/media
              - ./export:/usr/src/paperless/export
              - ./consume:/usr/src/paperless/consume
      '';

      dirs = {
        broker.once = true;
        consume.once = true;
        data.once = true;
        export.once = true;
        media.once = true;
      };

      envSecrets.webserver.PAPERLESS_SECRET_KEY = config.age.secrets.paperless-secret-key.path;
    };

    age.secrets.paperless-secret-key = {
      file = stack.secrets.serviceKey "paperless" "secret-key";
      owner = composeSecretUser;
      group = composeSecretUser;
    };
  };
}
