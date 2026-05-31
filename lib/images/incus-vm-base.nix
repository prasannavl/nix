{hostName, ...}: {
  imports = [
    ../profiles/incus-vm.nix
    (import ../incus-vm.nix {inherit hostName;})
    (import ../../users/pvl).lxc
  ];
}
