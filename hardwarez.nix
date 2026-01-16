{
  config,
  pkgs,
  ...
}: {
  hardware.enableAllFirmware = true;
  hardware.i2c.enable = true;
  hardware.amdgpu.initrd.enable = true;
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

  # NVIDIA hardware settings
  hardware.nvidia = {
    modesetting.enable = true;
    powerManagement.enable = true;
    powerManagement.finegrained = true;
    open = true;
    nvidiaSettings = true;
    nvidiaPersistenced = false;
    dynamicBoost.enable = true;
    # forceFullCompositionPipeline = true;
    prime = {
      offload.enable = true;
      offload.enableOffloadCmd = true;
      amdgpuBusId = "PCI:102:0:0";
      nvidiaBusId = "PCI:100:0:0";
    };
    package = config.boot.kernelPackages.nvidiaPackages.mkDriver {
      # version = "580.119.02";
      # sha256_64bit = "sha256-gCD139PuiK7no4mQ0MPSr+VHUemhcLqerdfqZwE47Nc=";
      # openSha256 = "sha256-l3IQDoopOt0n0+Ig+Ee3AOcFCGJXhbH1Q1nh1TEAHTE=";
      # settingsSha256 = "sha256-sI/ly6gNaUw0QZFWWkMbrkSstzf0hvcdSaogTUoTecI=";

      version = "580.126.09";
      sha256_64bit = "sha256-TKxT5I+K3/Zh1HyHiO0kBZokjJ/YCYzq/QiKSYmG7CY=";
      openSha256 = "sha256-ychsaurbQ2KNFr/SAprKI2tlvAigoKoFU1H7+SaxSrY=";
      settingsSha256 = "sha256-4SfCWp3swUp+x+4cuIZ7SA5H7/NoizqgPJ6S9fm90fA=";
      persistencedSha256 = pkgs.lib.fakeHash; # Not used with NvidiaPersistenced = false.
    };
  };
  hardware.nvidia-container-toolkit.enable = true;

  # X server configuration
  services.xserver.videoDrivers = ["nvidia"];

  # Other hardware related services
  services.fwupd.enable = true;
  services.power-profiles-daemon.enable = true;
  # For SSDs
  services.fstrim.enable = true;

  # ASUS
  #
  # Adds the missing asus functionality to Linux.
  # https://asus-linux.org/manual/asusctl-manual/
  services.asusd = {
    enable = true;
    # We don't need this, A14 doesn't
    # have the LED.
    # enableUserService = true;
  };
  services.supergfxd.enable = true;
  services.hardware.openrgb.enable = true;

  services.keyd = {
    enable = true;
    keyboards = {
      default = {
        ids = ["0001:0001:3cf016cc"];
        settings = {
          main = {
            # Right ctrl Key mapping
            "leftmeta+leftshift+f23" = "layer(control)";
          };
        };
      };
    };
  };

  # Sysrq key maps due to the lack of print scr
  services.udev.extraHwdb = ''
    # AT Translated Set 2 keyboard
    evdev:name:AT Translated Set 2 keyboard:*
     KEYBOARD_KEY_dd=sysrq

    # Asus WMI hotkeys
    evdev:name:Asus WMI hotkeys:*
     KEYBOARD_KEY_38=sysrq
  '';
  services.udev.packages = [pkgs.openrgb];
}
