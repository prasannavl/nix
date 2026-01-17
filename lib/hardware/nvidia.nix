{
  config,
  pkgs,
  ...
}: {
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
      amdgpuBusId = "PCI:102:0:0";
      nvidiaBusId = "PCI:100:0:0";
    };
    package = config.boot.kernelPackages.nvidiaPackages.mkDriver {
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
}
