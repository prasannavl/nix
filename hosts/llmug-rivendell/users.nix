{pkgs, ...}: {
  imports = [
    (import ../../users/pvl).systemd-container
  ];

  users.groups.llmug = {
    gid = 2000;
  };

  users.users.llmug = {
    isNormalUser = true;
    uid = 2000;
    group = "llmug";
    home = "/var/lib/llmug";
    createHome = true;
    shell = pkgs.bashInteractive;
    hashedPassword = "!";
    linger = true;
    extraGroups = ["wheel" "video" "render" "audio"];
  };
}
