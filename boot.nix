{ config, pkgs, ... }:
{
  boot.loader = {
    timeout = 3;
    systemd-boot.enable = true;
    efi.canTouchEfiVariables = true;
  };
  boot.initrd.systemd = {
    enable = true;
    tpm2.enable = true;
  };
  boot.kernelParams = [
    # "video=HDMI-A-1:1920x1080@60e"  
  ];
  boot.kernelPackages = pkgs.linuxPackages_latest;
}
