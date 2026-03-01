{
  lib,
  pkgs,
  ...
}: let
  userdata = (import ../../users/userdata.nix).nixbot;
  sshKeys =
    if userdata ? sshKeys
    then userdata.sshKeys
    else [userdata.sshKey];
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

  # Machine-scoped agenix identity used for activation-time decrypts.
  age.identityPaths = ["/var/lib/nixbot/.age/identity"];

  system.activationScripts.nixbotAgenixIdentityDir = ''
    install -d -m 0700 -o root -g root /var/lib/nixbot/.age
  '';

  systemd.tmpfiles.rules = [
    "d /var/lib/nixbot/.age 0700 root root -"
  ];
}
