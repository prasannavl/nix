{ config, pkgs, lib, ... }:
let
  userdata = import ./modules/userdata.nix;
in
{
    users.mutableUsers = false;
    
    users.users.root = {
      hashedPassword = "!"; # Disable
    };

    users.groups.i2c = { };

    users.groups.${userdata.pvl.username} = {
      gid = userdata.pvl.uid;
    };

    users.users.${userdata.pvl.username} = {
      isNormalUser = true;
      description = userdata.pvl.name;
      uid = userdata.pvl.uid;
      group = userdata.pvl.username;
      hashedPassword = userdata.pvl.hashedPassword;
      extraGroups = [ "users" "networkmanager" "wheel" "tss" "seat"  "i2c" "incus-admin" "podman" ];
      openssh.authorizedKeys.keys = [ userdata.pvl.sshKey ];
      packages = with pkgs; [];
    };

    users.users.gnome-remote-desktop.extraGroups = [ "tss" ];
}
