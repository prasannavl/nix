_: {
  users = {
    mutableUsers = false;
    users.root = {
      hashedPassword = "!"; # Disable
    };
    groups = {
      i2c = {};
      # Fix missing groups referenced by dbus
      netdev = {};
    };
  };

  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  # home-manager.backupFileExtension = "hm.backup";
}
