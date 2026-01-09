{ config, pkgs, ... }:
{
  hardware.enableAllFirmware = true;
  hardware.logitech.wireless.enable = true;
  
  # AMD Strix / ASUS bug, ignore microcode until BIOS update
  hardware.cpu.amd.updateMicrocode = false;

  # Hardware graphics configuration
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
    package = pkgs.mesa;
    package32 = pkgs.pkgsi686Linux.mesa;
    
    extraPackages = with pkgs; [
      libva
      libva-vdpau-driver
      libvdpau-va-gl
      nvidia-vaapi-driver
    ];
    extraPackages32 = with pkgs.pkgsi686Linux; [
      libva
      libva-vdpau-driver
      libvdpau-va-gl
      nvidia-vaapi-driver
    ];
  };

  # NVIDIA driver package configuration
  hardware.nvidia.package = config.boot.kernelPackages.nvidiaPackages.mkDriver {
    version = "580.119.02";
    sha256_64bit = "sha256-gCD139PuiK7no4mQ0MPSr+VHUemhcLqerdfqZwE47Nc=";
    openSha256 = "sha256-l3IQDoopOt0n0+Ig+Ee3AOcFCGJXhbH1Q1nh1TEAHTE=";
    settingsSha256 = "sha256-sI/ly6gNaUw0QZFWWkMbrkSstzf0hvcdSaogTUoTecI=";
    persistencedSha256 = pkgs.lib.fakeHash;
  };

  # NVIDIA hardware settings
  hardware.nvidia = {
    modesetting.enable = true;
    powerManagement.enable = true;
    powerManagement.finegrained = true;
    open = true;
    nvidiaSettings = true;
    nvidiaPersistenced = false;
    prime = {
      offload.enable = true;
      amdgpuBusId = "PCI:102:0:0";
      nvidiaBusId = "PCI:100:0:0";
    };
  };

  # X server configuration
  services.xserver.videoDrivers = [ "nvidia" ];
}
