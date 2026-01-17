{...}: {
  users.mutableUsers = false;

  users.users.root = {
    hashedPassword = "!"; # Disable
  };

  users.groups.i2c = {};
  # Fix missing groups referenced by dbus
  users.groups.netdev = {};

  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  # home-manager.backupFileExtension = "hm.backup";
}
