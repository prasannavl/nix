{...}: {
  imports = [
    ../../lib/nixbot/ci.nix
    ../pvl-common.nix
    ../../lib/devices/gmtek-evo-x2.nix
    ./cloudflare.nix
    ./sys.nix
    ./packages.nix
    ./firewall.nix
    ./services
    ./incus.nix
    ./users.nix
  ];
}
