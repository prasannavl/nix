{
  machineProfiles,
  mkNixosSystem,
  stacks,
  ...
}: let
  ab = import ../ab;
  systemComponent = ab.system;
  incusImages = import ../ab/runtime/incus/images.nix;
  hosts = import ../hosts {
    inherit machineProfiles mkNixosSystem stacks;
  };
  installer = import ./installer.nix {};
  installerImages = systemComponent.installer.images {
    inherit hosts mkNixosSystem;
    moduleFor = installer.moduleFor;
  };
  nixbotBase = {
    accounts,
    lib,
    ...
  }: let
    userdata = accounts.users.nixbot;
  in {
    imports = [(import ../users/pvl).core];
    services.nixbot = {
      enable = lib.mkDefault true;
      user.authorizedKeys = lib.mkDefault userdata.sshKeys;
    };
  };
in {
  installer = installerImages;

  incus-lxc-base = incusImages.mkBase {
    inherit mkNixosSystem;
    machineProfile = machineProfiles.incusLxc;
    modules = [nixbotBase];
  };

  incus-vm-base = incusImages.mkBase {
    inherit mkNixosSystem;
    machineProfile = machineProfiles.incusVm;
    modules = [nixbotBase];
  };
}
