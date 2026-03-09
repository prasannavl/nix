{config, ...}: {
  services.podmanCompose.pvl = {
    user = "pvl";
    stackDir = "/var/lib/pvl/compose";
    servicePrefix = "pvl-";

    instances = {
      beszel = {
        source = ./compose/beszel/docker-compose.yml;
        envSecrets."beszel-agent" = {
          KEY = config.age.secrets.beszel-key.path;
          TOKEN = config.age.secrets.beszel-token.path;
        };
      };

      dockge = {
        workDir,
        stackDir,
        podmanSocket,
        ...
      }: {
        source = {
          services.dockge = {
            image = "louislam/dockge:1";
            restart = "unless-stopped";
            user = "0:0";
            ports = ["5001:5001"];
            volumes = [
              "${podmanSocket}:/var/run/docker.sock"
              "${workDir}/data:/app/data"
              "${stackDir}:${stackDir}"
            ];
            environment.DOCKGE_STACKS_DIR = stackDir;
          };
        };
      };

      portainer.source = ./compose/portainer/docker-compose.yml;

      nginx = {
        source = ./compose/nginx/compose.yaml;
        files.".env" = ./compose/nginx/.env;
      };

      shadowsocks = {
        source = ./compose/shadowsocks/docker-compose.yml;
        envSecrets.shadowsocks.PASSWORD = config.age.secrets.shadowsocks-password.path;
      };

      immich = {
        source = ./compose/immich/docker-compose.yml;
        files = {
          "hwaccel.ml.yml" = ./compose/immich/hwaccel.ml.yml;
          "hwaccel.transcoding.yml" = ./compose/immich/hwaccel.transcoding.yml;
          ".env" = ./compose/immich/.env;
        };
        envSecrets = {
          immich-server.DB_PASSWORD = config.age.secrets.immich-db-password.path;
          database.POSTGRES_PASSWORD = config.age.secrets.immich-db-password.path;
        };
      };

      memos.source = ./compose/memos/docker-compose.yaml;
      ollama.source = ./compose/ollama/docker-compose.yml;
      docmost = {
        source = ./compose/docmost/docker-compose.yml;
        envSecrets = {
          docmost = {
            APP_SECRET = config.age.secrets.docmost-app-secret.path;
            DATABASE_URL = config.age.secrets.docmost-database-url.path;
          };
          db.POSTGRES_PASSWORD = config.age.secrets.docmost-postgres-password.path;
        };
      };
      vaultwarden.source = ./compose/vaultwarden/docker-compose.yml;

      # opencloud = {
      #   entryFile = [
      #     "docker-compose.yml"
      #     "weboffice/collabora.yml"
      #     "external-proxy/opencloud.yml"
      #     "external-proxy/collabora.yml"
      #     "search/tika.yml"
      #   ];
      #   files = {
      #     "" = ./compose/opencloud2;
      #   };
      # };

      # zulip.source = ./compose/zulip/docker-compose.yml;

      # outline = {
      #   source = ./compose/outline/docker-compose.yaml;
      #   files = {
      #     ".env" = ./compose/outline/.env;
      #     "redis.conf" = ./compose/outline/redis.conf;
      #   };
      # };
    };
  };

  age.secrets = let
    composeSecretUser = "pvl";
    mkComposeSecret = service: fileName: let
      resolvedFileName =
        if fileName == null
        then service
        else fileName;
    in {
      file = ../../data/secrets/services/${service}/${resolvedFileName}.key.age;
      owner = composeSecretUser;
      group = composeSecretUser;
    };
  in {
    beszel-key = mkComposeSecret "beszel" "key";
    beszel-token = mkComposeSecret "beszel" "token";
    docmost-app-secret = mkComposeSecret "docmost" "app-secret";
    docmost-database-url = mkComposeSecret "docmost" "database-url";
    docmost-postgres-password = mkComposeSecret "docmost" "postgres-password";
    immich-db-password = mkComposeSecret "immich" "db-password";
    shadowsocks-password = mkComposeSecret "shadowsocks" "password";
  };
}
