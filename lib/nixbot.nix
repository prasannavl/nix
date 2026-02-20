{...}: let
  deploySshKey = (import ../users/userdata.nix).pvl.sshKey;
in {
  users.users.nixbot = {
    isNormalUser = true;
    description = "Automated deployment user";
    createHome = true;
    home = "/var/lib/nixbot";
    hashedPassword = "!";
    openssh.authorizedKeys.keys = [deploySshKey];
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
}
