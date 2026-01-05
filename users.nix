{ config, pkgs, ... }:
{
  users.mutableUsers = false;
  
  users.users.root = {
    hashedPassword = "!"; # Disable
  };

  users.users.pvl = {
    isNormalUser = true;
    description = "Prasanna";
    uid = 1000;
    group = "pvl";
    extraGroups = [ "users" "networkmanager" "wheel" "tss" "seat" "incus-admin" ];
    packages = with pkgs; [];
    hashedPassword = "$y$j9T$9OEq0GBdps2U6P3EwZ2MH0$dTky3GP2ZSSIYGIpdeM8YXBo10LqOJVtycc5XR.ncw3";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIAAsB0nJcxF0wjuzXK0VTF1jbQbT24C1MM8NesCuwBb"
    ];
  };
  users.groups.pvl = {
    gid = 1000;
  };

  users.users.gnome-remote-desktop.extraGroups = [ "tss" ];
}
