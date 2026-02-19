{...}: {
  imports = [
    ../../lib/devices/gmtek-evo-x2.nix
    ../../lib/swap-auto.nix
    ../../lib/profiles/all.nix
    ./sys.nix
    ./packages.nix
    ./firewall.nix
    ./users.nix
  ];
}
