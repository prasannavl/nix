{...}: {
  imports = [
    ../../lib/nixbot/bastion.nix
    ../../lib/incus.nix
    ../../lib/podman.nix
    ../../lib/podman-compose
    ../../lib/devices/gmtek-evo-x2.nix
    ../../lib/swap-auto.nix
    ../../lib/profiles/all.nix
    ./cloudflare.nix
    ./sys.nix
    ./packages.nix
    ./firewall.nix
    ./services.nix
    ./incus.nix
    ./users.nix
  ];
}
