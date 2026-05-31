{hostName, ...}: {
  imports = [
    ../profiles/lxc.nix
    (import ../incus-vm.nix {inherit hostName;})
    (import ../../users/pvl).lxc
  ];
}
