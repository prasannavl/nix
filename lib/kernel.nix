{pkgs, ...}: {
  boot.kernelParams = [
    "quiet"
    "fbcon=map:0"
    # "vt.global_cursor_default=0"
    # "video=HDMI-A-1:1920x1080@60e"
  ];

  boot.kernelPackages = pkgs.linuxPackages_latest;
}
