{config, ...}: {
  config = {
    services.podmanCompose.pvl.instances.beszel = {podmanSocket, ...}: rec {
      exposedPorts.http = {
        port = 8090;
        openFirewall = true;
      };

      source = ./docker.compose.yaml;

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

    age.secrets = let
      composeSecretUser = "pvl";
    in {
      beszel-key = {
        file = ../../../../data/secrets/services/beszel/key.key.age;
        owner = composeSecretUser;
        group = composeSecretUser;
      };
      beszel-token = {
        file = ../../../../data/secrets/services/beszel/token.key.age;
        owner = composeSecretUser;
        group = composeSecretUser;
      };
    };
  };
}
