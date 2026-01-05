{ config, pkgs, lib, ... }:
let
  userinfo = import ./data/users.nix;
in
{
    users.mutableUsers = false;
    
    users.users.root = {
      hashedPassword = "!"; # Disable
    };

    users.users.pvl = {
      isNormalUser = true;
      description = userinfo.pvl.name;
      uid = 1000;
      group = "pvl";
      hashedPassword = userinfo.pvl.hashedPassword;
      extraGroups = [ "users" "networkmanager" "wheel" "tss" "seat" "incus-admin" ];
      openssh.authorizedKeys.keys = [ userinfo.pvl.sshKey ];
      packages = with pkgs; [];
    };
    
    users.groups.pvl = {
      gid = 1000;
    };

    users.users.gnome-remote-desktop.extraGroups = [ "tss" ];
}
