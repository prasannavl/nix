{...}: {
  services.podmanCompose.pvl = {
    user = "pvl";

    services.beszel.source = {
      services = {
        beszel = {
          image = "henrygd/beszel:latest";
          container_name = "beszel";
          restart = "unless-stopped";
          ports = ["8090:8090"];
          volumes = [
            "./beszel_data:/beszel_data"
            "./beszel_socket:/beszel_socket"
          ];
        };

        beszel-agent = {
          image = "henrygd/beszel-agent:latest";
          container_name = "beszel-agent";
          restart = "unless-stopped";
          network_mode = "host";
          volumes = [
            "./beszel_agent_data:/var/lib/beszel-agent"
            "./beszel_socket:/beszel_socket"
            "/var/run/user/1000/podman/podman.sock:/var/run/docker.sock:ro"
          ];
          environment = {
            LISTEN = 45876;
            HUB_URL = "http://localhost:8090";
            KEY = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKrQ7N9+5zgW/Ihz0sAX+fN7ozqXCyx0GjrtLHN8bwl7";
            TOKEN = "WfENPiJKKJNqbhPJbepQ";
          };
        };
      };
    };

    services.dockge.source = {
      services.dockge = {
        image = "louislam/dockge:1";
        restart = "unless-stopped";
        user = "0:0";
        ports = ["5001:5001"];
        volumes = [
          "/var/run/user/1000/podman/podman.sock:/var/run/docker.sock"
          "./data:/app/data"
          "/home/pvl/srv:/home/pvl/srv"
        ];
        environment.DOCKGE_STACKS_DIR = "/home/pvl/srv";
      };
    };

    services.docmost.source = {
      services = {
        docmost = {
          image = "docker.io/docmost/docmost:latest";
          user = "0:0";
          depends_on = [
            "db"
            "redis"
          ];
          environment = {
            APP_URL = "https://docs.p7log.com";
            APP_SECRET = "01230123012301230123012301230123";
            DATABASE_URL = "postgresql://docmost:STRONG_DB_PASSWORD@db:5432/docmost?schema=public";
            REDIS_URL = "redis://redis:6379";
          };
          ports = ["3000:3000"];
          restart = "always";
          volumes = ["./data:/app/data/storage"];
        };

        db = {
          image = "docker.io/postgres:16-alpine";
          environment = {
            POSTGRES_DB = "docmost";
            POSTGRES_USER = "docmost";
            POSTGRES_PASSWORD = "STRONG_DB_PASSWORD";
          };
          restart = "unless-stopped";
          volumes = ["./db-data:/var/lib/postgresql/data"];
        };

        redis = {
          image = "docker.io/redis:7.2-alpine";
          restart = "unless-stopped";
          user = "0:0";
          volumes = ["./cache:/data"];
        };
      };
    };

    services.immich = {
      source = {
        name = "immich";
        services = {
          immich-server = {
            container_name = "immich_server";
            image = "ghcr.io/immich-app/immich-server:\${IMMICH_VERSION:-release}";
            extends = {
              file = "hwaccel.transcoding.yml";
              service = "vaapi";
            };
            volumes = [
              "\${UPLOAD_LOCATION}:/data"
              "/etc/localtime:/etc/localtime:ro"
            ];
            env_file = [".env"];
            ports = ["2283:2283"];
            depends_on = [
              "redis"
              "database"
            ];
            restart = "always";
          };

          immich-machine-learning = {
            container_name = "immich_machine_learning";
            image = "ghcr.io/immich-app/immich-machine-learning:\${IMMICH_VERSION:-release}";
            extends = {
              file = "hwaccel.ml.yml";
              service = "rocm";
            };
            volumes = ["model-cache:/cache"];
            env_file = [".env"];
            restart = "always";
          };

          redis = {
            container_name = "immich_redis";
            image = "docker.io/valkey/valkey:8@sha256:81db6d39e1bba3b3ff32bd3a1b19a6d69690f94a3954ec131277b9a26b95b3aa";
            healthcheck.test = "redis-cli ping || exit 1";
            restart = "always";
          };

          database = {
            container_name = "immich_postgres";
            image = "ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0@sha256:bcf63357191b76a916ae5eb93464d65c07511da41e3bf7a8416db519b40b1c23";
            environment = {
              POSTGRES_PASSWORD = "\${DB_PASSWORD}";
              POSTGRES_USER = "\${DB_USERNAME}";
              POSTGRES_DB = "\${DB_DATABASE_NAME}";
              POSTGRES_INITDB_ARGS = "--data-checksums";
            };
            volumes = ["\${DB_DATA_LOCATION}:/var/lib/postgresql/data"];
            shm_size = "128mb";
            restart = "always";
          };
        };
        volumes.model-cache = {};
      };

      files = {
        "hwaccel.ml.yml" = {
          services.rocm = {
            group_add = ["video"];
            devices = [
              "/dev/dri:/dev/dri"
              "/dev/kfd:/dev/kfd"
            ];
          };
        };

        "hwaccel.transcoding.yml" = {
          services.vaapi.devices = ["/dev/dri:/dev/dri"];
        };

        ".env" = ''
          UPLOAD_LOCATION=./data
          DB_DATA_LOCATION=./postgres
          IMMICH_VERSION=release
          DB_PASSWORD=postgres
          DB_USERNAME=postgres
          DB_DATABASE_NAME=immich
        '';
      };
    };
  };
}
