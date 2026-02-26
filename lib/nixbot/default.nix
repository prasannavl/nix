{lib, pkgs, ...}: let
  userdata = (import ../../users/userdata.nix).nixbot;
  sshKeys = if userdata ? sshKeys then userdata.sshKeys else [userdata.sshKey];
in {
  users.groups.nixbot = {
    gid = userdata.uid;
  };

  users.users.nixbot = {
    uid = userdata.uid;
    group = "nixbot";
    isSystemUser = true;
    description = "nixbot - automation bot for nix deployments";
    hashedPassword = "!";
    createHome = true;
    home = "/var/lib/nixbot";
    shell = pkgs.bashInteractive;
    openssh.authorizedKeys.keys = sshKeys;
  };

  security.sudo.extraRules = [
    {
      users = ["nixbot"];
      commands = [
        {
          command = "ALL";
          options = ["NOPASSWD"];
        }
      ];
    }
  ];

  services.openssh.extraConfig = lib.mkAfter ''
    Match User nixbot
      PasswordAuthentication no
      KbdInteractiveAuthentication no
      AuthenticationMethods publickey
  '';

  nix.settings.trusted-users = lib.mkAfter ["nixbot"];
}
