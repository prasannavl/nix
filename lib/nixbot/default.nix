{lib, pkgs, ...}: let
  userdata = (import ../../users/userdata.nix).nixbot;
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
    openssh.authorizedKeys.keys = [userdata.sshKey];
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

  nix.settings.trusted-users = lib.mkAfter ["nixbot"];
}
