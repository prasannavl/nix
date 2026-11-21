{pkgs, ...}: {
  boot.kernelParams = [
    "quiet"
    "fbcon=map:0"
  ];

  boot.kernelPackages = pkgs.linuxPackages_latest;
  # boot.kernelPackages = pkgs.linuxKernel.packages.linux_7_0;
}
