{hostName, ...}: {
  imports = [
    ../../lib/profiles/lxc.nix
    (import ../../lib/incus-vm.nix {inherit hostName;})
    ../../lib/incus
    ../../lib/podman.nix
    ./incus.nix
    ./packages.nix
    ./firewall.nix
    ./services.nix
    ./users.nix
  ];
}
