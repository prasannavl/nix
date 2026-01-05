{ config, pkgs, lib, ... }:
let
  userdata = import ./data/userdata.nix;
in
{
    users.mutableUsers = false;
    
    users.users.root = {
      hashedPassword = "!"; # Disable
    };

    users.users.${userdata.pvl.username} = {
      isNormalUser = true;
      description = userdata.pvl.name;
      uid = userdata.pvl.uid;
      group = userdata.pvl.username;
      hashedPassword = userdata.pvl.hashedPassword;
      extraGroups = [ "users" "networkmanager" "wheel" "tss" "seat" "incus-admin" ];
      openssh.authorizedKeys.keys = [ userdata.pvl.sshKey ];
      packages = with pkgs; [];
    };
    
    users.groups.${userdata.pvl.username} = {
      gid = userdata.pvl.uid;
    };

    users.users.gnome-remote-desktop.extraGroups = [ "tss" ];
}
