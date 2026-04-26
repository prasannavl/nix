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
