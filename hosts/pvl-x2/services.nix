{
  config,
  lib,
  ...
}: let
  nginxLib = import ../../lib/nginx {inherit lib;};
  proxyVhosts = config.x.nginxProxyVhosts;
in {
  config = {
    x.nginxProxyVhosts = {
      docmost = {
        service = "docmost";
        serverNames = ["docmost.example.com"];
        port = 3000;
      };
      memos = {
        service = "memos";
        serverNames = ["memos.example.com"];
        port = 5230;
      };
      vaultwarden = {
        service = "vaultwarden";
        serverNames = ["vaultwarden.example.com"];
        port = 2000;
      };
    };

    services.podmanCompose.pvl = {
      user = "pvl";
      stackDir = "/var/lib/pvl/compose";
      servicePrefix = "pvl-";

      instances = rec {
        beszel = {podmanSocket, ...}: rec {
          exposedPorts.http = {
            port = 8090;
            openFirewall = true;
          };

          source = ./compose/beszel/docker-compose.yml;

          files.".env" = ''
            BESZEL_HTTP_PORT=${toString exposedPorts.http.port}
            BESZEL_HUB_URL=http://localhost:${toString exposedPorts.http.port}
            PODMAN_SOCKET=${podmanSocket}
          '';

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
        }: rec {
          exposedPorts.http = {
            port = 5001;
            openFirewall = true;
          };

          source = {
            services.dockge = {
              image = "louislam/dockge:1";
              restart = "unless-stopped";
              user = "0:0";
              ports = ["${toString exposedPorts.http.port}:5001"];
              volumes = [
                "${podmanSocket}:/var/run/docker.sock"
                "${workDir}/data:/app/data"
                "${stackDir}:${stackDir}"
              ];
              environment.DOCKGE_STACKS_DIR = stackDir;
            };
          };
        };

        portainer = {podmanSocket, ...}: rec {
          exposedPorts = {
            http = {
              port = 8001;
              openFirewall = true;
            };
            https.port = 9444;
          };

          source = ./compose/portainer/docker-compose.yml;

          files.".env" = ''
            PORTAINER_HTTP_PORT=${toString exposedPorts.http.port}
            PORTAINER_HTTPS_PORT=${toString exposedPorts.https.port}
            PODMAN_SOCKET=${podmanSocket}
          '';
        };

        nginx = rec {
          exposedPorts.http.port = 10800;
          dependsOn = nginxLib.dependencyServices proxyVhosts;

          source = nginxLib.composeSource;
          files =
            nginxLib.baseFiles
            // {
              ".env" = ''
                NGINX_HTTP_PORT=${toString exposedPorts.http.port}
              '';
              "conf.d/srv-http-ports.conf" = nginxLib.renderProxyServers proxyVhosts;
            };
        };

        shadowsocks = rec {
          exposedPorts.main = {
            port = 8388;
            protocols = [
              "tcp"
              "udp"
            ];
            openFirewall = true;
          };

          source = ./compose/shadowsocks/docker-compose.yml;

          files.".env" = ''
            SHADOWSOCKS_PORT=${toString exposedPorts.main.port}
          '';

          envSecrets.shadowsocks.PASSWORD = config.age.secrets.shadowsocks-password.path;
        };

        immich = rec {
          exposedPorts.http = {
            port = 2283;
            openFirewall = true;
          };

          source = ./compose/immich/docker-compose.yml;

          files = {
            ".env" = ''
              UPLOAD_LOCATION=./data
              DB_DATA_LOCATION=./postgres
              IMMICH_VERSION=release
              IMMICH_HTTP_PORT=${toString exposedPorts.http.port}
              DB_USERNAME=postgres
              DB_DATABASE_NAME=immich
            '';
            "hwaccel.ml.yml" = ./compose/immich/hwaccel.ml.yml;
            "hwaccel.transcoding.yml" = ./compose/immich/hwaccel.transcoding.yml;
          };

          envSecrets = {
            immich-server.DB_PASSWORD = config.age.secrets.immich-db-password.path;
            database.POSTGRES_PASSWORD = config.age.secrets.immich-db-password.path;
          };
        };

        memos = rec {
          exposedPorts.http = {
            port = proxyVhosts.memos.port;
            openFirewall = true;
          };

          source = ./compose/memos/docker-compose.yaml;

          files.".env" = ''
            MEMOS_HTTP_PORT=${toString exposedPorts.http.port}
          '';
        };

        ollama = rec {
          exposedPorts.main = {
            port = 11434;
            openFirewall = true;
          };

          source = ./compose/ollama/docker-compose.yml;

          files.".env" = ''
            OLLAMA_API_PORT=${toString exposedPorts.main.port}
          '';
        };

        openwebui = rec {
          exposedPorts.http = {
            port = 4000;
            openFirewall = true;
          };

          source = ./compose/openwebui/docker-compose.yml;
          dependsOn = ["ollama"];

          files.".env" = ''
            OLLAMA_API_PORT=${toString ollama.exposedPorts.main.port}
            OPEN_WEBUI_PORT=${toString exposedPorts.http.port}
          '';
        };

        docmost = rec {
          exposedPorts.http = {
            port = proxyVhosts.docmost.port;
            openFirewall = true;
          };

          source = ./compose/docmost/docker-compose.yml;

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

        vaultwarden = rec {
          exposedPorts.http = {
            port = proxyVhosts.vaultwarden.port;
            openFirewall = true;
          };

          source = ./compose/vaultwarden/docker-compose.yml;

          files.".env" = ''
            VAULTWARDEN_HTTP_PORT=${toString exposedPorts.http.port}
          '';
        };

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
  };
}
