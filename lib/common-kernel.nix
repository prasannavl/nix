{pkgs, ...}: {
  imports = [
    ./sysctl-kernel-coredump.nix
    ./sysctl-inotify.nix
    ./sysctl-kernel-panic.nix
    ./sysctl-kernel-sysrq.nix
  ];

  boot.kernelParams = [
    "quiet"
    "fbcon=map:0"
    "vt.global_cursor_default=0"
    # "video=HDMI-A-1:1920x1080@60e"
  ];
  boot.kernel.sysctl = {
    # swappiness
    "vm.swappiness" = 5;
  };

  boot.kernelPackages = pkgs.linuxPackages_latest;
}
