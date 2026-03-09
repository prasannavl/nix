{...}: {
  services.podmanCompose.pvl = {
    user = "pvl";
    stackDir = "/var/lib/pvl/compose";
    servicePrefix = "pvl-";

    instances = {
      # beszel.source = ./compose/beszel/docker-compose.yml;

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

      # portainer.source = ./compose/portainer/docker-compose.yml;

      # nginx = {
      #   source = ./compose/nginx/compose.yaml;
      #   files.".env" = ./compose/nginx/.env;
      # };

      # shadowsocks.source = ./compose/shadowsocks/docker-compose.yml;

      # immich = {
      #   source = ./compose/immich/docker-compose.yml;
      #   files = {
      #     "hwaccel.ml.yml" = ./compose/immich/hwaccel.ml.yml;
      #     "hwaccel.transcoding.yml" = ./compose/immich/hwaccel.transcoding.yml;
      #     ".env" = ./compose/immich/.env;
      #   };
      # };

      # memos.source = ./compose/memos/docker-compose.yaml;
      # ollama.source = ./compose/ollama/docker-compose.yml;
      # docmost.source = ./compose/docmost/docker-compose.yml;
      # vaultwarden.source = ./compose/vaultwarden/docker-compose.yml;

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
}
