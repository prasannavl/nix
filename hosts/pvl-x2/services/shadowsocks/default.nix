{config, ...}: let
  composeSecretUser = "pvl";
in {
  config = {
    services.podmanCompose.pvl.instances.shadowsocks = rec {
      exposedPorts.main = {
        port = 8388;
        protocols = [
          "tcp"
          "udp"
        ];
        openFirewall = true;
      };

      source = ./docker.compose.yaml;

      files.".env" = ''
        SHADOWSOCKS_PORT=${toString exposedPorts.main.port}
      '';

      envSecrets.shadowsocks.PASSWORD = config.age.secrets.shadowsocks-password.path;
    };

    age.secrets.shadowsocks-password = {
      file = ../../../../data/secrets/services/shadowsocks/password.key.age;
      owner = composeSecretUser;
      group = composeSecretUser;
    };
  };
}
