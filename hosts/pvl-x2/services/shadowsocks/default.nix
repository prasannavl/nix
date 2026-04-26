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

      source = ''
        services:
          shadowsocks:
            image: shadowsocks/shadowsocks-libev
            ports:
              - "${toString exposedPorts.main.port}:8388/tcp"
              - "${toString exposedPorts.main.port}:8388/udp"
            environment:
              - METHOD=aes-256-gcm
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
