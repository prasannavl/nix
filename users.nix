{ config, pkgs, lib, ... }:
let
  userdata = import ./modules/userdata.nix;
in
{
    users.mutableUsers = false;
    
    users.users.root = {
      hashedPassword = "!"; # Disable
    };

    users.groups.i2c = {};
    # Fix missing groups referenced by dbus/keyd
    users.groups.netdev = {};
    users.groups.keyd = {};

    users.groups.${userdata.pvl.username} = {
      gid = userdata.pvl.uid;
    };

    users.users.${userdata.pvl.username} = {
      isNormalUser = true;
      description = userdata.pvl.name;
      uid = userdata.pvl.uid;
      group = userdata.pvl.username;
      hashedPassword = userdata.pvl.hashedPassword;
      extraGroups = [ "users" "networkmanager" "wheel" "tss" "seat"  "i2c" "incus-admin" "podman" "keyd" ];
      openssh.authorizedKeys.keys = [ userdata.pvl.sshKey ];
      packages = with pkgs; [];

      # For distrobox, podman, flatpak, etc
      # subUidRanges = [ { startUid = 100000; count = 65536; } ];
      # subGidRanges = [ { startGid = 100000; count = 65536; } ];
    };

    users.users.gnome-remote-desktop.extraGroups = [ "tss" ];
}
