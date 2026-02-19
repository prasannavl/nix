{
  config,
  pkgs,
  ...
}: {
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
}
