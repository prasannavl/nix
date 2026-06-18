{
  machineProfiles,
  mkNixosSystem,
  stacks,
  ...
}: let
  hosts = import ../../hosts {
    inherit machineProfiles mkNixosSystem stacks;
  };
  installerImages = import ../installer {
    inherit mkNixosSystem stacks hosts;
  };
in {
  installer = installerImages;

  incus-lxc-base = mkNixosSystem {
    system = "x86_64-linux";
    hostName = "nixos";
    stack = stacks.all;
    machineProfile = machineProfiles.incusLxc;
    modules = [./incus-lxc-base.nix];
  };

  incus-vm-base = mkNixosSystem {
    system = "x86_64-linux";
    hostName = "nixos";
    stack = stacks.all;
    machineProfile = machineProfiles.incusVm;
    modules = [./incus-vm-base.nix];
  };
}
