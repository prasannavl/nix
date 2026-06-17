{...}: {
  imports = [
    ../common/all.nix
    ../../lib/incus
    ../../lib/podman.nix
    ./incus.nix
    ./packages.nix
    ./firewall.nix
    ./services.nix
    ./users.nix
  ];
}
