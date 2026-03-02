{pkgs, ...}: {
  boot.kernelParams = [
    "quiet"
    "fbcon=map:0"
    # "vt.global_cursor_default=0"
    # "video=eDP-1:2560x1600@165"
    # "video=eDP-2:2560x1600@165"
    # "video=DP-1:3840x1600@60e"
    # "video=DP-2:3840x1600@60e"
    # "video=DP-3:3840x1600@60e"
    # "video=DP-4:3840x1600@60e"
    # "video=DP-5:3840x1600@60e"
    # "video=DP-6:3840x1600@60e"
    # "video=DP-7:3840x1600@60e"
    # "video=DP-8:3840x1600@60e"
    # "video=DP-9:3840x1600@60e"
    # "video=HDMI-A-1:3840x1600@60e"
  ];

  boot.kernelPackages = pkgs.linuxPackages_latest;
  # boot.kernelPackages = pkgs.linuxKernel.packages.linux_6_18;
}
