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
  incusLxcBase = mkNixosSystem {
    system = "x86_64-linux";
    hostName = "nixos";
    stack = stacks.all;
    machineProfile = machineProfiles.incusLxc;
    modules = [./incus-lxc-base.nix];
  };
in {
  installer = installerImages;

  incus-lxc-base = incusLxcBase;
  incus-vm-base = mkNixosSystem {
    system = "x86_64-linux";
    hostName = "nixos";
    stack = stacks.all;
    machineProfile = machineProfiles.incusVm;
    modules = [./incus-vm-base.nix];
  };

  # Compatibility aliases for local host definitions that still reference the
  # pre-VM split names directly.
  incus-base = incusLxcBase;
  gap3-base = incusLxcBase;
}
