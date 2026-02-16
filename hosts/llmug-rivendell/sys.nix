{
  config,
  pkgs,
  ...
}: {
  # This host is designed to run as a container image (shared kernel).
  boot.isContainer = true;

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  users.mutableUsers = false;

  users.groups.llmug = {
    gid = 2000;
  };

  users.users.llmug = {
    isNormalUser = true;
    uid = 2000;
    group = "llmug";
    hashedPassword = "!";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIAAsB0nJcxF0wjuzXK0VTF1jbQbT24C1MM8NesCuwBb"
    ];
    extraGroups = ["wheel" "video" "render" "audio"];
  };

  security.sudo.wheelNeedsPassword = false;

  environment.sessionVariables = {
    NIXOS_OZONE_WL = "1";
  };
}
