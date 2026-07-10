{
  config,
  stack,
  ...
}: let
  composeSecretUser = "pvl";
in {
  config = {
    services.podman-compose.pvl.instances.shadowsocks = rec {
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
            image: docker.io/shadowsocks/shadowsocks-libev:v3.3.5
            ports:
              - "${toString exposedPorts.main.port}:8388/tcp"
              - "${toString exposedPorts.main.port}:8388/udp"
            environment:
              - METHOD=aes-256-gcm
      '';

      envSecrets.shadowsocks.PASSWORD = config.age.secrets.shadowsocks-password.path;
    };

    age.secrets.shadowsocks-password = {
      file = stack.secrets.serviceKey "shadowsocks" "password";
      owner = composeSecretUser;
      group = composeSecretUser;
    };
  };
}
