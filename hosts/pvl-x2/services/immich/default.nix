{
  config,
  stack,
  ...
}: let
  composeSecretUser = "pvl";
in {
  config = {
    services.podman-compose.pvl.instances.immich = rec {
      exposedPorts.http = {
        port = 2283;
        openFirewall = true;
      };

      source = ''
        name: immich

        services:
          immich-server:
            container_name: immich_server
            image: ghcr.io/immich-app/immich-server:''${IMMICH_VERSION:-release}
            user: 0:0
            extends:
              file: hwaccel.transcoding.yml
              service: vaapi
            volumes:
              - ''${UPLOAD_LOCATION}:/data
              - /etc/localtime:/etc/localtime:ro
            env_file:
              - .env
            ports:
              - "${toString exposedPorts.http.port}:2283"
            depends_on:
              - redis
              - database
            healthcheck:
              disable: false

          immich-machine-learning:
            container_name: immich_machine_learning
            image: ghcr.io/immich-app/immich-machine-learning:''${IMMICH_VERSION:-release}
            user: 0:0
            volumes:
              - model-cache:/cache
            env_file:
              - .env
            healthcheck:
              disable: false

          redis:
            container_name: immich_redis
            image: docker.io/valkey/valkey:9@sha256:546304417feac0874c3dd576e0952c6bb8f06bb4093ea0c9ca303c73cf458f63
            user: 0:0
            healthcheck:
              test: redis-cli ping || exit 1

          database:
            container_name: immich_postgres
            image: ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0@sha256:bcf63357191b76a916ae5eb93464d65c07511da41e3bf7a8416db519b40b1c23
            environment:
              POSTGRES_USER: ''${DB_USERNAME}
              POSTGRES_DB: ''${DB_DATABASE_NAME}
              POSTGRES_INITDB_ARGS: "--data-checksums"
            user: 0:0
            volumes:
              - ''${DB_DATA_LOCATION}:/var/lib/postgresql/data
            shm_size: 128mb
            healthcheck:
              disable: false

        volumes:
          model-cache:
      '';

      envSecrets = {
        immich-server.DB_PASSWORD = config.age.secrets.immich-db-password.path;
        database.POSTGRES_PASSWORD = config.age.secrets.immich-db-password.path;
      };

      files = {
        ".env".text = ''
          UPLOAD_LOCATION=./data
          DB_DATA_LOCATION=./postgres
          IMMICH_VERSION=release
          DB_USERNAME=postgres
          DB_DATABASE_NAME=immich
        '';
        "hwaccel.ml.yml".source = ./hwaccel.ml.yml;
        "hwaccel.transcoding.yml".source = ./hwaccel.transcoding.yml;
      };
    };

    age.secrets.immich-db-password = {
      file = stack.secrets.serviceKey "immich" "db-password";
      owner = composeSecretUser;
      group = composeSecretUser;
    };
  };
}
