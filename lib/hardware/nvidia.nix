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
    nvidiaPersistenced = false;
    dynamicBoost.enable = true;
    # forceFullCompositionPipeline = true;
    prime = {
      offload.enable = true;
      offload.enableOffloadCmd = true;
    };
    package = config.boot.kernelPackages.nvidiaPackages.mkDriver {
      version = "580.126.18";
      sha256_64bit = "sha256-p3gbLhwtZcZYCRTHbnntRU0ClF34RxHAMwcKCSqatJ0=";
      openSha256 = "sha256-1Q2wuDdZ6KiA/2L3IDN4WXF8t63V/4+JfrFeADI1Cjg=";
      settingsSha256 = "sha256-QMx4rUPEGp/8Mc+Bd8UmIet/Qr0GY8bnT/oDN8GAoEI=";
      persistencedSha256 = "sha256-ZBfPZyQKW9SkVdJ5cy0cxGap2oc7kyYRDOeM0XyfHfI="; # Not used with NvidiaPersistenced = false.
    };
  };
  hardware.nvidia-container-toolkit.enable = true;

  # X server configuration
  services.xserver.videoDrivers = ["nvidia"];
}
