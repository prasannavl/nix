{...}: {
  hardware.amdgpu.initrd.enable = true;

  boot = {
    kernelParams = [
      "amdgpu.dcdebugmask=0x10"
    ];
    initrd.kernelModules = ["amdgpu"];
    kernelModules = ["amdgpu"];
  };
}
