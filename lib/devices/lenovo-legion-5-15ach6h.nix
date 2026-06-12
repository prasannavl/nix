{...}: {
  imports = [
    ../hardware/mesa.nix
    ../hardware/amdgpu-strix.nix
    ../hardware/nvidia.nix
    ../hardware/logitech.nix
    ../hardware/mt7921e.nix
    ../hardware/openrgb.nix
    ../hardware/tpm.nix
  ];

  hardware.nvidia = {
    nvidiaPersistenced = false;
    dynamicBoost.enable = false;
    prime = {
      offload.enable = true;
      reverseSync.enable = true;
      amdgpuBusId = "PCI:6:0:0";
      nvidiaBusId = "PCI:1:0:0";
    };
  };

  boot.extraModprobeConfig = ''
    # Attempt amdgpu binds before nvidia. This doesn't happen if the
    # PCI device comes earlier, but we try anyway.
    softdep nvidia pre: amdgpu
    softdep nvidia_drm pre: amdgpu
    softdep nouveau pre: amdgpu
  '';

  services = {
    udev.extraRules = ''
      KERNEL=="card*", KERNELS=="0000:06:00.0", SYMLINK+="dri/zcard-amd", SYMLINK+="dri/zcard-default"
      KERNEL=="renderD*", KERNELS=="0000:06:00.0", SYMLINK+="dri/zrender-amd", SYMLINK+="dri/zrender-default"
      KERNEL=="card*", KERNELS=="0000:01:00.0", SYMLINK+="dri/zcard-nvidia"
      KERNEL=="renderD*", KERNELS=="0000:01:00.0", SYMLINK+="dri/zrender-nvidia"
    '';
  };

  environment.sessionVariables = {
    # GNOME on vulkan wakes up the dGPU momentarily that causes a 2-3s gap
    # when opening new apps.
    GSK_RENDERER = "gl";
  };
}
