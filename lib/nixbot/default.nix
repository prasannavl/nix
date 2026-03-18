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

  # Try the shared nixbot SSH key first, then the machine-scoped agenix
  # identity used for activation-time decrypts.
  age.identityPaths = [
    "/var/lib/nixbot/.ssh/id_ed25519"
    "/var/lib/nixbot/.age/identity"
  ];

  system.activationScripts.nixbotHomeDir = ''
    install -d -m 0755 -o nixbot -g nixbot /var/lib/nixbot
  '';

  system.activationScripts.nixbotAgenixIdentityDir = ''
    install -d -m 0710 -o root -g nixbot /var/lib/nixbot/.age
  '';

  systemd.tmpfiles.rules = [
    "d /var/lib/nixbot 0755 nixbot nixbot -"
    "d /var/lib/nixbot/.age 0710 root nixbot -"
  ];
}
