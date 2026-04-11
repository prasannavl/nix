{config, ...}: let
  nginxPort = config.services.podmanCompose.pvl.instances.nginx.exposedPorts.http.port;
  composeSecretUser = "pvl";
in {
  config = {
    services.podmanCompose.pvl.instances.docmost = rec {
      exposedPorts.http = {
        port = 3000;
        openFirewall = true;
        nginxHostNames = ["docmost-x.p7log.com"];
        cfTunnelNames = ["docmost-x.p7log.com"];
        cfTunnelPort = nginxPort;
      };

      source = ./docker.compose.yaml;

      files.".env" = ''
        DOCMOST_HTTP_PORT=${toString exposedPorts.http.port}
      '';

      envSecrets = {
        docmost = {
          APP_SECRET = config.age.secrets.docmost-app-secret.path;
          DATABASE_URL = config.age.secrets.docmost-database-url.path;
        };
        db.POSTGRES_PASSWORD = config.age.secrets.docmost-postgres-password.path;
      };
    };

    age.secrets = {
      docmost-app-secret = {
        file = ../../../../data/secrets/services/docmost/app-secret.key.age;
        owner = composeSecretUser;
        group = composeSecretUser;
      };
      docmost-database-url = {
        file = ../../../../data/secrets/services/docmost/database-url.key.age;
        owner = composeSecretUser;
        group = composeSecretUser;
      };
      docmost-postgres-password = {
        file = ../../../../data/secrets/services/docmost/postgres-password.key.age;
        owner = composeSecretUser;
        group = composeSecretUser;
      };
    };
  };
}
