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
      project = "pvl";
      allowedSubnets = ["10.10.50.0/24"];
      clientCertificateFile = "${incusClientCert}";
      clientKeyFile = config.age.secrets.incus-pvl-vlab-1-key.path;
      acceptCertificate = true;
      certificateDelegation.enable = true;
    };

    instances = {
      pvl-vk-1 = {
        ipv4Address = "10.10.50.31";
        config = {
          "security.privileged" = "false";
          "security.nesting" = "true";
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
