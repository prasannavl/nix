{...}: let
  incusSecrets = ../../data/secrets/globals/incus;
  clientKeyPath = "/run/agenix/incus-pvl-vlab-1-key";
in {
  age.secrets.incus-pvl-vlab-1-key = {
    file = incusSecrets + "/pvl-vlab-1.key.age";
    name = "incus-pvl-vlab-1-key";
  };

  services.incus-manager.global = {
    remote = {
      enable = true;
      name = "pvl-x2";
      address = "https://127.0.0.1:8443";
      projects.pvl.allowedSubnets = {
        ipv4 = "10.10.50.0/24";
        ipv6 = "fd42:8f14:377a:bdd3::/64";
      };
      clientCertificateFile = incusSecrets + "/pvl-vlab-1.crt";
      clientKeyFile = clientKeyPath;
      acceptCertificate = true;
    };
  };

  services.incus-manager.pvl.instances = {
    pvl-vk-1 = {
      network = {
        ipv4 = {
          address = "10.10.50.31";
          filtering = true;
        };
        ipv6 = {
          address = "fd42:8f14:377a:bdd3::31";
          filtering = true;
        };
      };
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
