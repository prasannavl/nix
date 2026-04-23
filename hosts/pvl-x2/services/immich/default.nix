{config, ...}: let
  composeSecretUser = "pvl";
in {
  config = {
    services.podmanCompose.pvl.instances.immich = rec {
      exposedPorts.http = {
        port = 2283;
        openFirewall = true;
      };

      source = ./docker.compose.yaml;

      envSecrets = {
        immich-server.DB_PASSWORD = config.age.secrets.immich-db-password.path;
        database.POSTGRES_PASSWORD = config.age.secrets.immich-db-password.path;
      };

      files = {
        ".env".text = ''
          UPLOAD_LOCATION=./data
          DB_DATA_LOCATION=./postgres
          IMMICH_VERSION=release
          IMMICH_HTTP_PORT=${toString exposedPorts.http.port}
          DB_USERNAME=postgres
          DB_DATABASE_NAME=immich
        '';
        "hwaccel.ml.yml".source = ./hwaccel.ml.yml;
        "hwaccel.transcoding.yml".source = ./hwaccel.transcoding.yml;
      };
    };

    age.secrets.immich-db-password = {
      file = ../../../../data/secrets/services/immich/db-password.key.age;
      owner = composeSecretUser;
      group = composeSecretUser;
    };
  };
}
