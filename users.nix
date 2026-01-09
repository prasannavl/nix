{
  config,
  pkgs,
  lib,
  ...
}: {
  imports = [
    ./users/pvl
  ];

  users.mutableUsers = false;

  users.users.root = {
    hashedPassword = "!"; # Disable
  };

  users.groups.i2c = {};
  # Fix missing groups referenced by dbus/keyd
  users.groups.netdev = {};
  users.groups.keyd = {};

  users.users.gnome-remote-desktop.extraGroups = ["tss"];

  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  # home-manager.backupFileExtension = "hm.backup";
}
