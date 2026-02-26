{...}: {
  imports = [
    ../../lib/nixbot/bastion.nix
    ../../lib/podman.nix
    ../../lib/devices/gmtek-evo-x2.nix
    ../../lib/swap-auto.nix
    ../../lib/profiles/all.nix
    ./sys.nix
    ./packages.nix
    ./firewall.nix
    ./services.nix
    ./incus.nix
    ./users.nix
  ];
}
