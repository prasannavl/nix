{
  config,
  pkgs,
  lib,
  ...
}: {
  boot.extraModprobeConfig = ''
    # default is /tmp, but we use tmpOnTmpfs
    # so we relieve this off the RAM
    options nvidia NVreg_TemporaryFilePath=/var/tmp
  '';

  hardware = {
    graphics = {
      extraPackages = with pkgs; [
        nvidia-vaapi-driver
      ];
      extraPackages32 = with pkgs.pkgsi686Linux; [
        nvidia-vaapi-driver
      ];
    };

    # NVIDIA hardware settings
    nvidia = {
      modesetting.enable = true;
      # nixpkgs defaults kernelSuspendNotifier to `open && version >= 595`. That
      # routes suspend/hibernate through the driver's kernel notifiers, and the
      # 595.91.07 open module returns status=0x11 from them
      # (`NVRM: PM suspend notifier failed: 0x11`). nixpkgs also then skips the
      # nvidia-suspend/resume/hibernate units entirely. Force the systemd
      # nvidia-sleep.sh path, which keeps PreserveVideoMemoryAllocations working.
      powerManagement = {
        enable = lib.mkDefault true;
        finegrained = lib.mkDefault true;
        kernelSuspendNotifier = lib.mkDefault false;
      };
      open = lib.mkDefault true;
      nvidiaSettings = lib.mkDefault true;
      dynamicBoost.enable = lib.mkDefault true;
      nvidiaPersistenced = lib.mkDefault false;
      # forceFullCompositionPipeline = true;
      prime = rec {
        offload.enable = true;
        offload.enableOffloadCmd = offload.enable;
        # For nvidia main GPU as  main renderer.
        # sync.enable = true;
      };
      package = pkgs.nvidiaCustomForKernel config.boot.kernelPackages;
    };

    nvidia-container-toolkit.enable = true;
  };

  systemd.services.nvidia-container-toolkit-cdi-generator.restartIfChanged = false;

  # X server configuration
  services.xserver.videoDrivers = ["nvidia"];
}
