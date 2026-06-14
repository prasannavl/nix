{hostName, ...}: {
  imports = [
    ../common/all.nix
    ../../lib/profiles/lxc.nix
    (import ../../lib/incus-vm.nix {inherit hostName;})
    ../../lib/podman.nix
    ./packages.nix
    ./users.nix
  ];
}
