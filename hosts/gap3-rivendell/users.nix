{pkgs, ...}: {
  imports = [
    (import ../../users/pvl).systemd-container
  ];

  users.groups.gap3 = {
    gid = 2000;
  };

  users.users.gap3 = {
    isNormalUser = true;
    uid = 2000;
    group = "gap3";
    home = "/var/lib/gap3";
    createHome = true;
    shell = pkgs.bashInteractive;
    hashedPassword = "!";
    linger = true;
    extraGroups = ["wheel" "video" "render" "audio"];
  };
}
