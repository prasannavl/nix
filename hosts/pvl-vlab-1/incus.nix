{
  config,
  pkgs,
  ...
}: let
  incusClientCert = pkgs.writeText "pvl-vlab-1-incus-client.crt" (builtins.readFile ../../data/secrets/incus/pvl-vlab-1.crt);
in {
  age.secrets.incus-pvl-vlab-1-key = {
    file = ../../data/secrets/incus/pvl-vlab-1.key.age;
  };

  services.incusMachines = {
    remote = {
      enable = true;
      name = "pvl-x2";
      address = "https://127.0.0.1:8443";
      project = "default";
      allowedSubnets = ["10.10.20.0/24"];
      clientCertificateFile = "${incusClientCert}";
      clientKeyFile = config.age.secrets.incus-pvl-vlab-1-key.path;
      acceptCertificate = true;
    };

    instances = {
      pvl-vk-1 = {
        ipv4Address = "10.10.20.31";
        config = {
          "security.privileged" = "false";
          "security.nesting" = "true";
          "security.syscalls.intercept.mount" = "true";
          "security.syscalls.intercept.mount.shift" = "true";
        };
        devices = {
          state = {
            source = "pvl-vk-1";
            path = "/var/lib";
            removalPolicy = "delete";
          };
        };
      };
    };
  };
}
