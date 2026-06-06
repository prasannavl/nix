{...}: let
  incusSecrets = ../../data/secrets/globals/incus;
  clientKeyPath = "/run/agenix/incus-pvl-vlab-1-key";
in {
  age.secrets.incus-pvl-vlab-1-key = {
    file = incusSecrets + "/pvl-vlab-1.key.age";
    name = "incus-pvl-vlab-1-key";
  };

  services.incusMachines.global = {
    remote = {
      enable = true;
      name = "pvl-x2";
      address = "https://127.0.0.1:8443";
      projects.pvl.allowedSubnets = "10.10.50.0/24";
      clientCertificateFile = incusSecrets + "/pvl-vlab-1.crt";
      clientKeyFile = clientKeyPath;
      acceptCertificate = true;
    };
  };

  services.incusMachines.pvl.instances = {
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
}
