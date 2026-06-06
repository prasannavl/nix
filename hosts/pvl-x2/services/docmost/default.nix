{
  config,
  stack,
  ...
}: let
  nginxPort = config.services.podmanCompose.pvl.instances.nginx.exposedPorts.http.port;
  composeSecretUser = "pvl";
  secretsBase = stack.secrets.service "docmost";
in {
  config = {
    services.podmanCompose.pvl.instances.docmost = rec {
      exposedPorts.http = {
        port = 3000;
        openFirewall = true;
        nginxHostNames = ["docmost-x.p7log.com"];
        cfTunnelNames = ["docmost-x.p7log.com"];
        cfTunnelPort = nginxPort;
        clientMaxBodySize = "250m";
      };

      source = ''
        version: "3"

        services:
          docmost:
            image: docker.io/docmost/docmost:latest
            user: 0:0
            depends_on:
              - db
              - redis
            environment:
              APP_URL: "https://docs.p7log.com"
              REDIS_URL: "redis://redis:6379"
            ports:
              - "${toString exposedPorts.http.port}:3000"
            volumes:
              - ./data:/app/data/storage

          db:
            image: docker.io/postgres:16-alpine
            user: 0:0
            environment:
              POSTGRES_DB: docmost
              POSTGRES_USER: docmost
            volumes:
              - ./db-data:/var/lib/postgresql/data

          redis:
            image: docker.io/redis:7.2-alpine
            user: 0:0
            volumes:
              - ./cache:/data
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
        file = secretsBase + "/app-secret.key.age";
        owner = composeSecretUser;
        group = composeSecretUser;
      };
      docmost-database-url = {
        file = secretsBase + "/database-url.key.age";
        owner = composeSecretUser;
        group = composeSecretUser;
      };
      docmost-postgres-password = {
        file = secretsBase + "/postgres-password.key.age";
        owner = composeSecretUser;
        group = composeSecretUser;
      };
    };
  };
}
