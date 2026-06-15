{
  config,
  lib,
  options,
  pkgs,
  ...
}: let
  harmoniaLessThan3 = version: lib.versionOlder version "3";
  signingKey = config.age.secrets.nix-builder-pvl-signing-key.path;
in {
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
    signingKey
  ];

  networking.firewall.allowedTCPPorts = [5000];

  services.harmonia = let
    cacheConfig = {
      enable = true;
      signKeyPaths = [signingKey];
      settings.bind = "0.0.0.0:5000";
    };
  in
    if harmoniaLessThan3 pkgs.harmonia.version || !(options.services.harmonia ? cache)
    then cacheConfig
    else {cache = cacheConfig;};

  age.secrets.nix-builder-pvl-signing-key = {
    file = ../../data/secrets/globals/nix/builder-pvl.key.age;
    owner = "root";
    group = "root";
    mode = "0400";
  };
}
