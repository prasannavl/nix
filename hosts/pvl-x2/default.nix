{config, ...}: {
  imports = [
    ../common/pvl.nix
    ../common/ci.nix
    ../../lib/devices/gmtek-evo-x2.nix
    ./cloudflare.nix
    ./sys.nix
    ./packages.nix
    ./firewall.nix
    ./services
    ./incus.nix
    ./users.nix
  ];

  nix.settings.secret-key-files = [
    config.age.secrets.nix-builder-pvl-signing-key.path
  ];

  networking.firewall.allowedTCPPorts = [5000];

  services.harmonia = {
    enable = true;
    signKeyPaths = [
      config.age.secrets.nix-builder-pvl-signing-key.path
    ];
    settings.bind = "0.0.0.0:5000";
  };

  age.secrets.nix-builder-pvl-signing-key = {
    file = ../../data/secrets/globals/nix/builder-pvl.key.age;
    owner = "root";
    group = "root";
    mode = "0400";
  };
}
