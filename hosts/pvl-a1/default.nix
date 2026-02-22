{
  lib,
  pkgs,
  ...
}: {
  imports = [
    ../../lib/devices/asus-fa401wv.nix
    ../../lib/swap-auto.nix
    ../../lib/profiles/all.nix
    ./sys.nix
    ./packages.nix
    ./firewall.nix
    ./podman.nix
    ./incus.nix
    ./users.nix
  ];
}
