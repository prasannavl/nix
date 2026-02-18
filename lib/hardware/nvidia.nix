{
  config,
  pkgs,
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
    powerManagement.enable = true;
    powerManagement.finegrained = true;
    open = true;
    nvidiaSettings = true;
    dynamicBoost.enable = true;
    nvidiaPersistenced = false;
    # forceFullCompositionPipeline = true;
    prime = {
      offload.enable = true;
      offload.enableOffloadCmd = true;
    };
    package = pkgs.callPackage ../../pkgs/nvidia-driver.nix {inherit config;};
  };
  hardware.nvidia-container-toolkit.enable = true;

  # X server configuration
  services.xserver.videoDrivers = ["nvidia"];
}
