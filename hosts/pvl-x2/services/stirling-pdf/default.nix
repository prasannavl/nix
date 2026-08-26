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
    services.podman-compose.pvl.instances.stirling-pdf = rec {
      exposedPorts.http = {
        port = registry.portFor "stirling-pdf" "http";
        openFirewall = true;
        nginxHostNames = registry.domains.stirling-pdf;
        tunnels = [
          {
            kind = "cloudflare";
            hostNames = registry.domains.stirling-pdf;
            targetPort = nginxPort;
          }
        ];
        clientMaxBodySize = "250m";
        proxyReadTimeout = "3600s";
        proxySendTimeout = "3600s";
      };

      source = ''
        services:
          stirling-pdf:
            image: docker.stirlingpdf.com/stirlingtools/stirling-pdf:2.14.3
            container_name: stirling-pdf
            user: 0:0
            environment:
              SECURITY_ENABLELOGIN: "true"
              SECURITY_INITIALLOGIN_USERNAME: admin
            ports:
              - "${toString exposedPorts.http.port}:8080"
            volumes:
              - ./configs:/configs
      '';

      dirs.configs.once = true;
      envSecrets.stirling-pdf.SECURITY_INITIALLOGIN_PASSWORD = config.age.secrets.stirling-pdf-admin-password.path;
    };

    age.secrets.stirling-pdf-admin-password = {
      file = stack.secrets.serviceKey "stirling-pdf" "admin-password";
      owner = composeSecretUser;
      group = composeSecretUser;
    };
  };
}
