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

  hardware.graphics.extraPackages = with pkgs; [
    nvidia-vaapi-driver
  ];
  hardware.graphics.extraPackages32 = with pkgs.pkgsi686Linux; [
    nvidia-vaapi-driver
  ];

  # NVIDIA hardware settings
  hardware.nvidia = {
    modesetting.enable = true;
    powerManagement.enable = lib.mkDefault true;
    powerManagement.finegrained = lib.mkDefault true;
    open = lib.mkDefault true;
    nvidiaSettings = lib.mkDefault true;
    nvidiaPersistenced = lib.mkDefault false;
    dynamicBoost.enable = lib.mkDefault false;
    # forceFullCompositionPipeline = true;
    prime = rec {
      offload.enable = true;
      offload.enableOffloadCmd = offload.enable;
      # For nvidia main GPU as  main renderer.
      # sync.enable = true;
    };
    package = pkgs.nvidiaCustomForKernel config.boot.kernelPackages;
  };
  hardware.nvidia-container-toolkit.enable = true;

  # X server configuration
  services.xserver.videoDrivers = ["nvidia"];
}
