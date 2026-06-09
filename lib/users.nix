{
  pkgs,
  lib,
  stack ? null,
  ...
}: let
  nixosConfig =
    if stack == null
    then {
      disabledUsers = {};
      disabledGroups = {};
      disabledActivationScripts = {};
    }
    else stack.nixosConfig {inherit lib pkgs;};
in {
  users = {
    mutableUsers = false;
    users =
      {
        root = {
          hashedPassword = "!"; # Disable
        };
      }
      // nixosConfig.disabledUsers;
    groups =
      {
        # Basic groups that might be needed
        # on first boot for some workloads.
        render = {};
        video = {};
        i2c = {};
        # Fix missing groups referenced by dbus
        netdev = {};
      }
      // nixosConfig.disabledGroups;
  };

  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  # home-manager.backupFileExtension = "hm.backup";

  system.activationScripts = nixosConfig.disabledActivationScripts;
}
